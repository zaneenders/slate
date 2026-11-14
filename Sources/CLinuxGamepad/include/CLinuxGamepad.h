#pragma once
#include <stdint.h>

// Fixed-size ABI; all storage is caller-owned. Only ioctl needs a C shim.
typedef struct {
  uint16_t buttons;
  int32_t x, y, x_minimum, x_maximum, y_minimum, y_maximum;
} slate_gamepad_state;

// 0 success, otherwise negative errno. Probe rejects non-gamepad evdev nodes.
int slate_gamepad_probe(int descriptor, uint8_t *hat_axes);
int slate_gamepad_read_state(int descriptor, uint8_t hat_axes, slate_gamepad_state *state);
