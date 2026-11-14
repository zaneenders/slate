#pragma once
#include <stdint.h>

typedef struct {
  uint32_t buttons;
  int32_t x, y, x_minimum, x_maximum, y_minimum, y_maximum;
  int32_t right_x, right_y, right_x_minimum, right_x_maximum, right_y_minimum, right_y_maximum;
  int32_t left_trigger, right_trigger, left_trigger_minimum, left_trigger_maximum;
  int32_t right_trigger_minimum, right_trigger_maximum;
} slate_gamepad_state;

typedef struct { uint32_t buttons; uint8_t axes; } slate_gamepad_capabilities;
typedef struct { uint16_t bus, vendor, product, version; char unique[128]; } slate_gamepad_identity;
typedef struct {
  uint8_t pressed;
  int32_t tracking[2], x[2], y[2];
  int32_t x_minimum, x_maximum, y_minimum, y_maximum;
} slate_gamepad_touch_state;

enum {
  SLATE_GAMEPAD_HAT_X = 1, SLATE_GAMEPAD_HAT_Y = 2, SLATE_GAMEPAD_RIGHT_STICK = 4,
  SLATE_GAMEPAD_LEFT_TRIGGER = 8, SLATE_GAMEPAD_RIGHT_TRIGGER = 16
};
// Every query returns 0 or negative errno, without retries. All caller storage is
// changed only on success. The injected-query variants let Linux fixtures verify
// the actual ioctl protocol without hardware, permissions, or process-wide hooks.
typedef int (*slate_gamepad_query)(int descriptor, unsigned long request, void *value);
int slate_gamepad_probe(int descriptor, slate_gamepad_capabilities *capabilities);
int slate_gamepad_read_state(int descriptor, uint8_t axes, slate_gamepad_state *state);
int slate_gamepad_get_identity(int descriptor, slate_gamepad_identity *identity);
int slate_gamepad_probe_touchpad(int descriptor, const slate_gamepad_identity *identity);
int slate_gamepad_read_touchpad(int descriptor, slate_gamepad_touch_state *state);
int slate_gamepad_probe_with_query(int, slate_gamepad_capabilities *, slate_gamepad_query);
int slate_gamepad_read_state_with_query(int, uint8_t, slate_gamepad_state *, slate_gamepad_query);
int slate_gamepad_get_identity_with_query(int, slate_gamepad_identity *, slate_gamepad_query);
int slate_gamepad_probe_touchpad_with_query(int, const slate_gamepad_identity *, slate_gamepad_query);
int slate_gamepad_read_touchpad_with_query(int, slate_gamepad_touch_state *, slate_gamepad_query);
