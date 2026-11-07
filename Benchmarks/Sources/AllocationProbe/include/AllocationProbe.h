#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void cli_probe_begin(void);
uint64_t cli_probe_end(void);
int cli_probe_calibrate(void);
void cli_probe_consume(const void *bytes, size_t count);

#ifdef __cplusplus
}
#endif
