#pragma once

#include <stddef.h>

// Spawn an isolated process group on a PTY, without running Swift after fork.
int cli_test_spawn_terminal(const char *path, int slave, int *child);
// 0 running, 1 stopped (signal), 2 exited (status), 3 killed (signal), -errno.
int cli_test_wait_terminal(int child, int *value);

#if defined(__linux__)
// Test-only, thread-local syscall scripts, copied synchronously. A negative step
// returns -1 with errno = -step, zero returns zero, and a positive step limits
// the next real syscall's byte count. Calls after the script use the real syscall.
void cli_test_read_script(const int *steps, size_t count);
// On the next read, raise this signal on the caller's thread and return EINTR.
// The caller owns the signal disposition/mask. Reset cancels a pending signal.
void cli_test_read_signal(int number);
void cli_test_write_script(const int *steps, size_t count);
// Negative steps fail with errno, zero simulates a timeout, positive steps call
// the real poll. Scripts are thread-local and limited to sixteen calls.
void cli_test_poll_script(const int *steps, size_t count);
void cli_test_reset_io(void);
#endif
