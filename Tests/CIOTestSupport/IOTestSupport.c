#include "CIOTestSupport.h"

#if defined(__linux__)
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  int steps[16];
  size_t count;
  size_t index;
} Script;

static _Thread_local Script reads;
static _Thread_local Script writes;
static _Thread_local Script polls;

static void configure(Script *script, const int *steps, size_t count) {
  assert(count <= 16);
  memcpy(script->steps, steps, count * sizeof(int));
  script->count = count;
  script->index = 0;
}

void cli_test_read_script(const int *steps, size_t count) {
  configure(&reads, steps, count);
}

void cli_test_write_script(const int *steps, size_t count) {
  configure(&writes, steps, count);
}

void cli_test_reset_io(void) {
  reads = (Script){0};
  writes = (Script){0};
  polls = (Script){0};
}

void cli_test_poll_script(const int *steps, size_t count) {
  configure(&polls, steps, count);
}

ssize_t __real_read(int fd, void *buffer, size_t count);
ssize_t __real_write(int fd, const void *buffer, size_t count);
int __real_poll(struct pollfd *fds, nfds_t count, int timeout);

int __wrap_poll(struct pollfd *fds, nfds_t count, int timeout) {
  if (polls.index < polls.count) {
    int step = polls.steps[polls.index++];
    if (step < 0) { errno = -step; return -1; }
    if (step == 0) {
      for (nfds_t i = 0; i < count; i++) fds[i].revents = 0;
      return 0;
    }
  }
  return __real_poll(fds, count, timeout);
}

ssize_t __wrap_read(int fd, void *buffer, size_t count) {
  if (reads.index < reads.count) {
    int step = reads.steps[reads.index++];
    if (step < 0) { errno = -step; return -1; }
    if (step == 0) return 0;
    if ((size_t)step < count) count = (size_t)step;
  }
  return __real_read(fd, buffer, count);
}

ssize_t __wrap_write(int fd, const void *buffer, size_t count) {
  if (writes.index < writes.count) {
    int step = writes.steps[writes.index++];
    if (step < 0) { errno = -step; return -1; }
    if (step == 0) return 0;
    if ((size_t)step < count) count = (size_t)step;
  }
  return __real_write(fd, buffer, count);
}

#endif
