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

int slate_gamepad_probe(int descriptor, uint8_t *hat_axes) {
  unsigned long keys[WORD_COUNT(KEY_CNT)] = {0};
  unsigned long axes[WORD_COUNT(ABS_CNT)] = {0};
  if (ioctl(descriptor, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) < 0) return -errno;
  if (!has_bit(keys, BTN_SOUTH) || !has_bit(keys, BTN_EAST)) return -ENOTSUP;
  if (ioctl(descriptor, EVIOCGBIT(EV_ABS, sizeof(axes)), axes) < 0) return -errno;
  if (!has_bit(axes, ABS_X) || !has_bit(axes, ABS_Y)) return -ENOTSUP;
  *hat_axes = (has_bit(axes, ABS_HAT0X) ? 1 : 0) | (has_bit(axes, ABS_HAT0Y) ? 2 : 0);
  return 0;
}

int slate_gamepad_read_state(int descriptor, uint8_t hat_axes, slate_gamepad_state *state) {
  unsigned long keys[WORD_COUNT(KEY_CNT)] = {0};
  struct input_absinfo x = {0}, y = {0}, hat_x = {0}, hat_y = {0};
  // Current-state queries avoid queue draining and recover immediately from
  // kernel event overflow (SYN_DROPPED). At most five ioctls per sample, no retries.
  if (ioctl(descriptor, EVIOCGKEY(sizeof(keys)), keys) < 0) return -errno;
  if (ioctl(descriptor, EVIOCGABS(ABS_X), &x) < 0) return -errno;
  if (ioctl(descriptor, EVIOCGABS(ABS_Y), &y) < 0) return -errno;
  if ((hat_axes & 1) && ioctl(descriptor, EVIOCGABS(ABS_HAT0X), &hat_x) < 0) return -errno;
  if ((hat_axes & 2) && ioctl(descriptor, EVIOCGABS(ABS_HAT0Y), &hat_y) < 0) return -errno;
  if (x.minimum >= x.maximum || y.minimum >= y.maximum) return -EINVAL;
  uint16_t buttons = 0;
  if (hat_y.value < 0 || has_bit(keys, BTN_DPAD_UP)) buttons |= 1 << 0;
  if (hat_y.value > 0 || has_bit(keys, BTN_DPAD_DOWN)) buttons |= 1 << 1;
  if (hat_x.value < 0 || has_bit(keys, BTN_DPAD_LEFT)) buttons |= 1 << 2;
  if (hat_x.value > 0 || has_bit(keys, BTN_DPAD_RIGHT)) buttons |= 1 << 3;
  if (has_bit(keys, BTN_SOUTH)) buttons |= 1 << 4;
  if (has_bit(keys, BTN_EAST)) buttons |= 1 << 5;
  if (has_bit(keys, BTN_WEST)) buttons |= 1 << 6;
  *state = (slate_gamepad_state){buttons, x.value, y.value, x.minimum, x.maximum, y.minimum, y.maximum};
  return 0;
}
#endif
