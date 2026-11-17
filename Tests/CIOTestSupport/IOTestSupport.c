#include "CIOTestSupport.h"

#if defined(__linux__)
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>

typedef struct {
  int steps[16];
  size_t count;
  size_t index;
} Script;

static _Thread_local Script reads;
static _Thread_local Script writes;
static _Thread_local Script polls;
static _Thread_local int readSignal;
static pthread_mutex_t sessionLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int sessionMode;
static Script sessionReads, sessionWrites, sessionPolls;
static int sessionReadSignal;
static dev_t sessionDevice;
static ino_t sessionInode;

static int session_target(int fd) {
  struct stat info;
  if (fstat(fd, &info) != 0) return 0;
  pthread_mutex_lock(&sessionLock);
  int matches = info.st_dev == sessionDevice && info.st_ino == sessionInode;
  pthread_mutex_unlock(&sessionLock);
  return matches;
}

void cli_test_session_io(int descriptor) {
  struct stat info;
  assert(fstat(descriptor, &info) == 0);
  pthread_mutex_lock(&sessionLock);
  sessionDevice = info.st_dev;
  sessionInode = info.st_ino;
  sessionReads = sessionWrites = sessionPolls = (Script){0};
  sessionReadSignal = 0;
  atomic_store(&sessionMode, 1);
  pthread_mutex_unlock(&sessionLock);
}

static void configure(Script *script, const int *steps, size_t count) {
  assert(count <= 16);
  memcpy(script->steps, steps, count * sizeof(int));
  script->count = count;
  script->index = 0;
}

void cli_test_read_script(const int *steps, size_t count) {
  if (atomic_load(&sessionMode)) {
    pthread_mutex_lock(&sessionLock);
    configure(&sessionReads, steps, count);
    pthread_mutex_unlock(&sessionLock);
  } else { configure(&reads, steps, count); }
}

void cli_test_read_signal(int number) {
  if (atomic_load(&sessionMode)) {
    pthread_mutex_lock(&sessionLock); sessionReadSignal = number; pthread_mutex_unlock(&sessionLock);
  } else { readSignal = number; }
}

void cli_test_write_script(const int *steps, size_t count) {
  if (atomic_load(&sessionMode)) {
    pthread_mutex_lock(&sessionLock);
    configure(&sessionWrites, steps, count);
    pthread_mutex_unlock(&sessionLock);
  } else { configure(&writes, steps, count); }
}

void cli_test_reset_io(void) {
  reads = (Script){0};
  writes = (Script){0};
  polls = (Script){0};
  readSignal = 0;
  atomic_store(&sessionMode, 0);
}

void cli_test_poll_script(const int *steps, size_t count) {
  if (atomic_load(&sessionMode)) {
    pthread_mutex_lock(&sessionLock);
    configure(&sessionPolls, steps, count);
    pthread_mutex_unlock(&sessionLock);
  } else { configure(&polls, steps, count); }
}

ssize_t __real_read(int fd, void *buffer, size_t count);
ssize_t __real_write(int fd, const void *buffer, size_t count);
int __real_poll(struct pollfd *fds, nfds_t count, int timeout);

int __wrap_poll(struct pollfd *fds, nfds_t count, int timeout) {
if (atomic_load(&sessionMode)) {
  if (count == 0 || !session_target(fds[0].fd)) return __real_poll(fds, count, timeout);
  pthread_mutex_lock(&sessionLock);
  int step = sessionPolls.index < sessionPolls.count ? sessionPolls.steps[sessionPolls.index++] : 1;
  pthread_mutex_unlock(&sessionLock);
  if (step < 0) { errno = -step; return -1; }
  if (step == 0) {
    for (nfds_t i = 0; i < count; i++) fds[i].revents = 0;
    return 0;
  }
  return __real_poll(fds, count, timeout);
}
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
if (atomic_load(&sessionMode)) {
  if (!session_target(fd)) return __real_read(fd, buffer, count);
  pthread_mutex_lock(&sessionLock);
  int number = sessionReadSignal;
  sessionReadSignal = 0;
  int step = sessionReads.index < sessionReads.count ? sessionReads.steps[sessionReads.index++] : (int)count;
  pthread_mutex_unlock(&sessionLock);
  if (number != 0) { raise(number); errno = EINTR; return -1; }
  if (step < 0) { errno = -step; return -1; }
  if ((size_t)step < count) count = (size_t)step;
  return count == 0 ? 0 : __real_read(fd, buffer, count);
}
if (readSignal != 0) {
    int number = readSignal;
    readSignal = 0;
    raise(number);
    errno = EINTR;
    return -1;
  }
  if (reads.index < reads.count) {
    int step = reads.steps[reads.index++];
    if (step < 0) { errno = -step; return -1; }
    if (step == 0) return 0;
    if ((size_t)step < count) count = (size_t)step;
  }
  return __real_read(fd, buffer, count);
}

ssize_t __wrap_write(int fd, const void *buffer, size_t count) {
if (atomic_load(&sessionMode)) {
  if (!session_target(fd)) return __real_write(fd, buffer, count);
  pthread_mutex_lock(&sessionLock);
  int step = sessionWrites.index < sessionWrites.count ? sessionWrites.steps[sessionWrites.index++] : (int)count;
  pthread_mutex_unlock(&sessionLock);
  if (step < 0) { errno = -step; return -1; }
  if ((size_t)step < count) count = (size_t)step;
  return count == 0 ? 0 : __real_write(fd, buffer, count);
}
if (writes.index < writes.count) {
    int step = writes.steps[writes.index++];
    if (step < 0) { errno = -step; return -1; }
    if (step == 0) return 0;
    if ((size_t)step < count) count = (size_t)step;
  }
  return __real_write(fd, buffer, count);
}

#endif
