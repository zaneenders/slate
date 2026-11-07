#include "AllocationProbe.h"
#include <errno.h>
#include <malloc.h>
#include <stdatomic.h>
#include <stdlib.h>

#if !defined(__GLIBC__)
#error "This allocation benchmark requires Linux Glibc."
#endif

// Calling Glibc directly avoids dlsym recursion during runtime initialization.
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void *__libc_memalign(size_t, size_t);

static _Atomic int enabled;
static _Atomic uint64_t allocations;
static volatile unsigned char sink;

static void record(void) {
  if (atomic_load_explicit(&enabled, memory_order_relaxed))
    atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
}

void *malloc(size_t size) { record(); return __libc_malloc(size); }
void *calloc(size_t count, size_t size) { record(); return __libc_calloc(count, size); }
void *realloc(void *pointer, size_t size) { record(); return __libc_realloc(pointer, size); }
void *memalign(size_t alignment, size_t size) {
  record();
  return __libc_memalign(alignment, size);
}
void *aligned_alloc(size_t alignment, size_t size) {
  record();
  if (!alignment || (alignment & (alignment - 1))) { errno = EINVAL; return NULL; }
  return __libc_memalign(alignment, size);
}
int posix_memalign(void **result, size_t alignment, size_t size) {
  record();
  if (alignment < sizeof(void *) || (alignment & (alignment - 1))) return EINVAL;
  int saved_errno = errno;
  void *memory = __libc_memalign(alignment, size);
  errno = saved_errno;
  if (!memory) return ENOMEM;
  *result = memory;
  return 0;
}

void cli_probe_begin(void) {
  atomic_store(&allocations, 0);
  atomic_store(&enabled, 1);
}

uint64_t cli_probe_end(void) {
  atomic_store(&enabled, 0);
  return atomic_load(&allocations);
}

int cli_probe_calibrate(void) {
  // Volatile function pointers prevent optimizing away malloc/free pairs.
  void *(*volatile allocate)(size_t) = malloc;
  void *(*volatile zero)(size_t, size_t) = calloc;
  void *(*volatile resize)(void *, size_t) = realloc;
  void *(*volatile align)(size_t, size_t) = memalign;
  void *(*volatile aligned)(size_t, size_t) = aligned_alloc;
  int (*volatile posix)(void **, size_t, size_t) = posix_memalign;
  void *memory = allocate(64);
  if (!memory) return 0;
  void *resized = resize(memory, 128);
  if (!resized) { free(memory); return 0; }
  free(resized);
  memory = zero(1, 64);
  if (!memory) return 0;
  free(memory);
  memory = align(64, 64);
  if (!memory) return 0;
  free(memory);
  memory = aligned(64, 64);
  if (!memory) return 0;
  free(memory);
  if (posix(&memory, 64, 64)) return 0;
  free(memory);
  return 1;
}

void cli_probe_consume(const void *bytes, size_t count) {
  const unsigned char *input = bytes;
  unsigned char sum = 0;
  for (size_t i = 0; i < count; ++i) sum ^= input[i];
  sink = sum;
}
