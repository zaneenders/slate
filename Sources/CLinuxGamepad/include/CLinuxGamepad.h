#pragma once
#include <stdint.h>

// Fixed-size ABI; all storage is caller-owned. Only ioctl needs a C shim.
typedef struct {
  uint16_t buttons;
  int32_t x, y, x_minimum, x_maximum, y_minimum, y_maximum;
  int32_t right_x, right_y, right_x_minimum, right_x_maximum, right_y_minimum, right_y_maximum;
} slate_gamepad_state;

// 0 success, otherwise negative errno. Probe rejects non-gamepad evdev nodes.
enum { SLATE_GAMEPAD_HAT_X = 1, SLATE_GAMEPAD_HAT_Y = 2, SLATE_GAMEPAD_RIGHT_STICK = 4 };
int slate_gamepad_probe(int descriptor, uint8_t *axis_flags);
int slate_gamepad_read_state(int descriptor, uint8_t axis_flags, slate_gamepad_state *state);
