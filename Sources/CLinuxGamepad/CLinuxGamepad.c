#include "CLinuxGamepad.h"

#if defined(__linux__)
#include <errno.h>
#include <linux/input.h>
#include <stddef.h>
#include <sys/ioctl.h>

#define WORD_BITS (sizeof(unsigned long) * 8)
#define WORD_COUNT(bits) (((bits) + WORD_BITS - 1) / WORD_BITS)
static int has_bit(const unsigned long *bits, unsigned int index) {
  return (bits[index / WORD_BITS] >> (index % WORD_BITS)) & 1UL;
}

int slate_gamepad_probe(int descriptor, uint8_t *axis_flags) {
  unsigned long keys[WORD_COUNT(KEY_CNT)] = {0};
  unsigned long axes[WORD_COUNT(ABS_CNT)] = {0};
  if (ioctl(descriptor, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) < 0) return -errno;
  if (!has_bit(keys, BTN_SOUTH) || !has_bit(keys, BTN_EAST)) return -ENOTSUP;
  if (ioctl(descriptor, EVIOCGBIT(EV_ABS, sizeof(axes)), axes) < 0) return -errno;
  if (!has_bit(axes, ABS_X) || !has_bit(axes, ABS_Y)) return -ENOTSUP;
  *axis_flags = (has_bit(axes, ABS_HAT0X) ? SLATE_GAMEPAD_HAT_X : 0)
    | (has_bit(axes, ABS_HAT0Y) ? SLATE_GAMEPAD_HAT_Y : 0);
  if (has_bit(axes, ABS_RX) && has_bit(axes, ABS_RY)) *axis_flags |= SLATE_GAMEPAD_RIGHT_STICK;
  return 0;
}

int slate_gamepad_read_state(int descriptor, uint8_t axis_flags, slate_gamepad_state *state) {
  unsigned long keys[WORD_COUNT(KEY_CNT)] = {0};
  struct input_absinfo x = {0}, y = {0}, hat_x = {0}, hat_y = {0};
  struct input_absinfo right_x = {0}, right_y = {0};
  // Current-state queries avoid queue draining and recover immediately from
  // kernel event overflow (SYN_DROPPED). At most seven ioctls per sample, no retries.
  if (ioctl(descriptor, EVIOCGKEY(sizeof(keys)), keys) < 0) return -errno;
  if (ioctl(descriptor, EVIOCGABS(ABS_X), &x) < 0) return -errno;
  if (ioctl(descriptor, EVIOCGABS(ABS_Y), &y) < 0) return -errno;
  if ((axis_flags & SLATE_GAMEPAD_HAT_X) && ioctl(descriptor, EVIOCGABS(ABS_HAT0X), &hat_x) < 0) return -errno;
  if ((axis_flags & SLATE_GAMEPAD_HAT_Y) && ioctl(descriptor, EVIOCGABS(ABS_HAT0Y), &hat_y) < 0) return -errno;
  if ((axis_flags & SLATE_GAMEPAD_RIGHT_STICK) && ioctl(descriptor, EVIOCGABS(ABS_RX), &right_x) < 0) return -errno;
  if ((axis_flags & SLATE_GAMEPAD_RIGHT_STICK) && ioctl(descriptor, EVIOCGABS(ABS_RY), &right_y) < 0) return -errno;
  if (x.minimum >= x.maximum || y.minimum >= y.maximum) return -EINVAL;
  uint16_t buttons = 0;
  if (hat_y.value < 0 || has_bit(keys, BTN_DPAD_UP)) buttons |= 1 << 0;
  if (hat_y.value > 0 || has_bit(keys, BTN_DPAD_DOWN)) buttons |= 1 << 1;
  if (hat_x.value < 0 || has_bit(keys, BTN_DPAD_LEFT)) buttons |= 1 << 2;
  if (hat_x.value > 0 || has_bit(keys, BTN_DPAD_RIGHT)) buttons |= 1 << 3;
  if (has_bit(keys, BTN_SOUTH)) buttons |= 1 << 4;
  if (has_bit(keys, BTN_EAST)) buttons |= 1 << 5;
  if (has_bit(keys, BTN_WEST)) buttons |= 1 << 6;
  if (has_bit(keys, BTN_NORTH)) buttons |= 1 << 7;
  if (has_bit(keys, BTN_TL)) buttons |= 1 << 8;
  if (has_bit(keys, BTN_TR)) buttons |= 1 << 9;
  *state = (slate_gamepad_state){
    buttons, x.value, y.value, x.minimum, x.maximum, y.minimum, y.maximum,
    right_x.value, right_y.value, right_x.minimum, right_x.maximum, right_y.minimum, right_y.maximum
  };
  return 0;
}
#endif
