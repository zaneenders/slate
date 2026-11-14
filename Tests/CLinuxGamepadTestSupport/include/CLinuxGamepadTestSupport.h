#pragma once
#include <CLinuxGamepad.h>
void slate_gamepad_fixture_reset(int scenario, int fail_at);
int slate_gamepad_fixture_query(int descriptor, unsigned long request, void *value);
int slate_gamepad_fixture_query_count(void);
