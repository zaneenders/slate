#include "CLinuxGamepad.h"

#if defined(__linux__)
#include <errno.h>
#include <linux/input.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>

#define WORD_BITS (sizeof(unsigned long) * 8)
#define WORD_COUNT(bits) (((bits) + WORD_BITS - 1) / WORD_BITS)
#define BUTTON(bit) (UINT32_C(1) << (bit))
static int has_bit(const unsigned long *bits, unsigned int index) {
  return (bits[index / WORD_BITS] >> (index % WORD_BITS)) & 1UL;
}
static int system_query(int descriptor, unsigned long request, void *value) {
  return ioctl(descriptor, request, value) < 0 ? -errno : 0;
}
static uint32_t button_mask(const unsigned long *keys) {
  static const struct { unsigned int code, bit; } mapping[] = {
    {BTN_DPAD_UP,0}, {BTN_DPAD_DOWN,1}, {BTN_DPAD_LEFT,2}, {BTN_DPAD_RIGHT,3},
    {BTN_SOUTH,4}, {BTN_EAST,5}, {BTN_WEST,6}, {BTN_NORTH,7}, {BTN_TL,8}, {BTN_TR,9},
    {BTN_TL2,10}, {BTN_TR2,11}, {BTN_THUMBL,12}, {BTN_THUMBR,13},
    {BTN_START,14}, {BTN_SELECT,15}, {BTN_MODE,16}, {KEY_MICMUTE,18}
  };
  uint32_t result = 0;
  for (size_t i = 0; i < sizeof(mapping) / sizeof(mapping[0]); ++i) {
    if (has_bit(keys, mapping[i].code)) result |= BUTTON(mapping[i].bit);
  }
  return result;
}

int slate_gamepad_probe_with_query(int fd, slate_gamepad_capabilities *capabilities, slate_gamepad_query query) {
  unsigned long keys[WORD_COUNT(KEY_CNT)] = {0}, axes[WORD_COUNT(ABS_CNT)] = {0};
  int result = query(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys);
  if (result < 0) return result;
  if (!has_bit(keys, BTN_SOUTH) || !has_bit(keys, BTN_EAST)) return -ENOTSUP;
  result = query(fd, EVIOCGBIT(EV_ABS, sizeof(axes)), axes);
  if (result < 0) return result;
  if (!has_bit(axes, ABS_X) || !has_bit(axes, ABS_Y)) return -ENOTSUP;
  slate_gamepad_capabilities value = {button_mask(keys), 0};
  if (has_bit(axes, ABS_HAT0X)) { value.axes |= SLATE_GAMEPAD_HAT_X; value.buttons |= BUTTON(2) | BUTTON(3); }
  if (has_bit(axes, ABS_HAT0Y)) { value.axes |= SLATE_GAMEPAD_HAT_Y; value.buttons |= BUTTON(0) | BUTTON(1); }
  if (has_bit(axes, ABS_RX) && has_bit(axes, ABS_RY)) value.axes |= SLATE_GAMEPAD_RIGHT_STICK;
  if (has_bit(axes, ABS_Z)) { value.axes |= SLATE_GAMEPAD_LEFT_TRIGGER; value.buttons |= BUTTON(10); }
  if (has_bit(axes, ABS_RZ)) { value.axes |= SLATE_GAMEPAD_RIGHT_TRIGGER; value.buttons |= BUTTON(11); }
  *capabilities = value;
  return 0;
}

int slate_gamepad_read_state_with_query(int fd, uint8_t flags, slate_gamepad_state *state, slate_gamepad_query query) {
  unsigned long keys[WORD_COUNT(KEY_CNT)] = {0};
  struct input_absinfo values[8] = {0};
  const unsigned int codes[8] = {ABS_X, ABS_Y, ABS_HAT0X, ABS_HAT0Y, ABS_RX, ABS_RY, ABS_Z, ABS_RZ};
  const uint8_t required[8] = {0, 0, SLATE_GAMEPAD_HAT_X, SLATE_GAMEPAD_HAT_Y,
    SLATE_GAMEPAD_RIGHT_STICK, SLATE_GAMEPAD_RIGHT_STICK, SLATE_GAMEPAD_LEFT_TRIGGER, SLATE_GAMEPAD_RIGHT_TRIGGER};
  // One key-state query and at most eight axis queries. Never drain event queues
  // or retry: current-state queries recover directly from SYN_DROPPED overflow.
  int result = query(fd, EVIOCGKEY(sizeof(keys)), keys);
  if (result < 0) return result;
  for (unsigned int i = 0; i < 8; ++i) {
    if (required[i] && !(flags & required[i])) continue;
    result = query(fd, EVIOCGABS(codes[i]), &values[i]);
    if (result < 0) return result;
  }
  if (values[0].minimum >= values[0].maximum || values[1].minimum >= values[1].maximum) return -EINVAL;
  uint32_t buttons = button_mask(keys);
  if (values[3].value < 0) buttons |= BUTTON(0);
  if (values[3].value > 0) buttons |= BUTTON(1);
  if (values[2].value < 0) buttons |= BUTTON(2);
  if (values[2].value > 0) buttons |= BUTTON(3);
  *state = (slate_gamepad_state){
    buttons, values[0].value, values[1].value, values[0].minimum, values[0].maximum, values[1].minimum, values[1].maximum,
    values[4].value, values[5].value, values[4].minimum, values[4].maximum, values[5].minimum, values[5].maximum,
    values[6].value, values[7].value, values[6].minimum, values[6].maximum, values[7].minimum, values[7].maximum
  };
  return 0;
}

int slate_gamepad_get_identity_with_query(int fd, slate_gamepad_identity *identity, slate_gamepad_query query) {
  struct input_id id = {0};
  slate_gamepad_identity value = {0};
  int result = query(fd, EVIOCGID, &id);
  if (result < 0) return result;
  result = query(fd, EVIOCGUNIQ(sizeof(value.unique)), value.unique);
  if (result < 0) return result;
  if (!value.unique[0]) return -ENOTSUP;
  if (!memchr(value.unique, 0, sizeof(value.unique))) return -EOVERFLOW;
  value.bus = id.bustype; value.vendor = id.vendor; value.product = id.product; value.version = id.version;
  *identity = value;
  return 0;
}

int slate_gamepad_probe_touchpad_with_query(int fd, const slate_gamepad_identity *identity, slate_gamepad_query query) {
  slate_gamepad_identity candidate = {0};
  int result = slate_gamepad_get_identity_with_query(fd, &candidate, query);
  if (result < 0) return result;
  if (candidate.bus != identity->bus || candidate.vendor != identity->vendor || candidate.product != identity->product
      || candidate.version != identity->version || !identity->unique[0]
      || strncmp(candidate.unique, identity->unique, sizeof(candidate.unique))) return -ENOTSUP;
  unsigned long keys[WORD_COUNT(KEY_CNT)] = {0}, axes[WORD_COUNT(ABS_CNT)] = {0};
  result = query(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys);
  if (result < 0) return result;
  if (!has_bit(keys, BTN_LEFT)) return -ENOTSUP;
  result = query(fd, EVIOCGBIT(EV_ABS, sizeof(axes)), axes);
  if (result < 0) return result;
  if (!has_bit(axes, ABS_MT_SLOT) || !has_bit(axes, ABS_MT_TRACKING_ID)
      || !has_bit(axes, ABS_MT_POSITION_X) || !has_bit(axes, ABS_MT_POSITION_Y)) return -ENOTSUP;
  struct input_absinfo slots = {0};
  result = query(fd, EVIOCGABS(ABS_MT_SLOT), &slots);
  if (result < 0) return result;
  return slots.minimum == 0 && slots.maximum >= 1 ? 0 : -ENOTSUP;
}

int slate_gamepad_read_touchpad_with_query(int fd, slate_gamepad_touch_state *state, slate_gamepad_query query) {
  unsigned long keys[WORD_COUNT(KEY_CNT)] = {0};
  struct input_absinfo x = {0}, y = {0};
  // Exactly two slots, three MT queries; six total queries and no heap storage.
  int32_t tracking[3] = {ABS_MT_TRACKING_ID, -1, -1};
  int32_t px[3] = {ABS_MT_POSITION_X, 0, 0}, py[3] = {ABS_MT_POSITION_Y, 0, 0};
  int result = query(fd, EVIOCGKEY(sizeof(keys)), keys);
  if (result < 0) return result;
  result = query(fd, EVIOCGABS(ABS_MT_POSITION_X), &x);
  if (result < 0) return result;
  result = query(fd, EVIOCGABS(ABS_MT_POSITION_Y), &y);
  if (result < 0) return result;
  result = query(fd, EVIOCGMTSLOTS(sizeof(tracking)), tracking);
  if (result < 0) return result;
  result = query(fd, EVIOCGMTSLOTS(sizeof(px)), px);
  if (result < 0) return result;
  result = query(fd, EVIOCGMTSLOTS(sizeof(py)), py);
  if (result < 0) return result;
  if (x.minimum >= x.maximum || y.minimum >= y.maximum) return -EINVAL;
  *state = (slate_gamepad_touch_state){
    has_bit(keys, BTN_LEFT), {tracking[1], tracking[2]}, {px[1], px[2]}, {py[1], py[2]},
    x.minimum, x.maximum, y.minimum, y.maximum
  };
  return 0;
}

int slate_gamepad_probe(int fd, slate_gamepad_capabilities *value) {
  return slate_gamepad_probe_with_query(fd, value, system_query);
}
int slate_gamepad_read_state(int fd, uint8_t flags, slate_gamepad_state *value) {
  return slate_gamepad_read_state_with_query(fd, flags, value, system_query);
}
int slate_gamepad_get_identity(int fd, slate_gamepad_identity *value) {
  return slate_gamepad_get_identity_with_query(fd, value, system_query);
}
int slate_gamepad_probe_touchpad(int fd, const slate_gamepad_identity *identity) {
  return slate_gamepad_probe_touchpad_with_query(fd, identity, system_query);
}
int slate_gamepad_read_touchpad(int fd, slate_gamepad_touch_state *value) {
  return slate_gamepad_read_touchpad_with_query(fd, value, system_query);
}
#endif
