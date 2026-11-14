#include "CLinuxGamepadTestSupport.h"
#if defined(__linux__)
#include <errno.h>
#include <linux/input.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>
static _Thread_local int scenario;
static _Thread_local int fail_at;
static _Thread_local int query_count;
void slate_gamepad_fixture_reset(int value, int failure) { scenario = value; fail_at = failure; query_count = 0; }
int slate_gamepad_fixture_query_count(void) { return query_count; }
static void bit(void *value, unsigned int index) {
  unsigned long *words = value;
  words[index / (sizeof(unsigned long) * 8)] |= 1UL << (index % (sizeof(unsigned long) * 8));
}
int slate_gamepad_fixture_query(int fd, unsigned long request, void *value) {
  if (++query_count == fail_at) return -EIO;
  const unsigned int nr = _IOC_NR(request);
  if (nr == 0x0a) {
    int32_t *slots = value;
    switch (slots[0]) {
      case ABS_MT_TRACKING_ID: slots[1] = 42; slots[2] = -1; break;
      case ABS_MT_POSITION_X: slots[1] = 960; slots[2] = 1500; break;
      case ABS_MT_POSITION_Y: slots[1] = 540; slots[2] = 800; break;
      default: return -EINVAL;
    }
    return 0;
  }
  memset(value, 0, _IOC_SIZE(request));
  if (request == EVIOCGID) {
    *(struct input_id *)value = (struct input_id){BUS_USB, 0x054c, 0x0ce6, 1};
    return 0;
  }
  if (nr == 0x08) {
    if (scenario == 1) return 0; // No stable identity: pairing must be rejected.
    if (scenario == 2 && fd == 2) { memset(value, 'x', _IOC_SIZE(request)); return 0; }
    const char *id = fd == 3 ? "other-controller" : "01:02:03:04:05:06";
    memcpy(value, id, strlen(id) + 1);
    return 0;
  }
  if (nr == 0x18 || nr == 0x20 + EV_KEY) {
    if (fd == 2 || fd == 3) { bit(value, BTN_LEFT); return 0; }
    if (scenario == 3) return 0; // An unrelated input node.
    static const unsigned int keys[] = {
      BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT,
      BTN_SOUTH, BTN_EAST, BTN_WEST, BTN_NORTH, BTN_TL, BTN_TR, BTN_TL2, BTN_TR2,
      BTN_THUMBL, BTN_THUMBR, BTN_START, BTN_SELECT, BTN_MODE, KEY_MICMUTE
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) bit(value, keys[i]);
    return 0;
  }
  if (nr == 0x20 + EV_ABS) {
    if (fd == 2 || fd == 3) {
      bit(value, ABS_MT_SLOT); bit(value, ABS_MT_TRACKING_ID);
      bit(value, ABS_MT_POSITION_X); bit(value, ABS_MT_POSITION_Y);
    } else {
      bit(value, ABS_X); bit(value, ABS_Y); bit(value, ABS_HAT0X); bit(value, ABS_HAT0Y);
      bit(value, ABS_RX); bit(value, ABS_RY);
      if (scenario != 4) { bit(value, ABS_Z); bit(value, ABS_RZ); }
    }
    return 0;
  }
  if (nr >= 0x40 && nr <= 0x40 + ABS_MAX) {
    const unsigned int code = nr - 0x40;
    struct input_absinfo *axis = value;
    axis->minimum = 0; axis->maximum = 255;
    switch (code) {
      case ABS_X: axis->value = 255; break;
      case ABS_Y: axis->value = 0; break;
      case ABS_RX: axis->value = 64; break;
      case ABS_RY: axis->value = 192; break;
      case ABS_Z: axis->value = 255; break;
      case ABS_RZ: axis->value = 128; break;
      case ABS_HAT0X: axis->minimum = -1; axis->maximum = 1; axis->value = -1; break;
      case ABS_HAT0Y: axis->minimum = -1; axis->maximum = 1; axis->value = 1; break;
      case ABS_MT_SLOT: axis->maximum = scenario == 5 ? 0 : 1; break;
      case ABS_MT_POSITION_X: axis->maximum = 1919; break;
      case ABS_MT_POSITION_Y: axis->maximum = 1079; break;
      default: return -EINVAL;
    }
    if (scenario == 6) axis->maximum = axis->minimum;
    return 0;
  }
  return -EINVAL;
}
#endif
