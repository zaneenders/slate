// Opt-in glibc interposer, loaded only by check-render-allocations.sh.
// Counts outermost allocation API calls on the measured thread. mmap, custom
// allocators, and allocations on other threads are outside this probe.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

// dlsym can allocate while resolving the allocator itself. Bootstrap those
// calls through glibc until the original entry points have been resolved.
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);

static _Atomic(pthread_t) owner;
static bool inside_allocator;
static uint64_t calls;

void slate_allocation_probe_begin(void) {
  pthread_t expected = 0;
  if (!atomic_compare_exchange_strong(&owner, &expected, pthread_self())) abort();
  calls = 0;
}

uint64_t slate_allocation_probe_end(void) {
  if (atomic_load(&owner) != pthread_self()) abort();
  uint64_t result = calls;
  atomic_store(&owner, 0);
  return result;
}

static void *(*original_malloc)(size_t) = __libc_malloc;
static void *(*original_calloc)(size_t, size_t) = __libc_calloc;
static void *(*original_realloc)(void *, size_t) = __libc_realloc;
static void *(*original_valloc)(size_t);
static void *(*original_aligned_alloc)(size_t, size_t);
static int (*original_posix_memalign)(void **, size_t, size_t);

__attribute__((constructor)) static void resolve_allocators(void) {
  original_malloc = dlsym(RTLD_NEXT, "malloc");
  original_calloc = dlsym(RTLD_NEXT, "calloc");
  original_realloc = dlsym(RTLD_NEXT, "realloc");
  original_valloc = dlsym(RTLD_NEXT, "valloc");
  original_aligned_alloc = dlsym(RTLD_NEXT, "aligned_alloc");
  original_posix_memalign = dlsym(RTLD_NEXT, "posix_memalign");
  if (!original_malloc || !original_calloc || !original_realloc || !original_valloc
      || !original_aligned_alloc || !original_posix_memalign) abort();
}

#define PROBE(result_type, name, parameters, arguments) \
  result_type name parameters { \
    if (!original_##name) { \
      original_##name = dlsym(RTLD_NEXT, #name); \
      if (!original_##name) abort(); \
    } \
    pthread_t active = atomic_load(&owner); \
    bool record = active != 0 && active == pthread_self() && !inside_allocator; \
    if (record) { \
      if (calls != UINT64_MAX) calls++; \
      inside_allocator = true; \
    } \
    result_type result = original_##name arguments; \
    if (record) inside_allocator = false; \
    return result; \
  }

PROBE(void *, malloc, (size_t size), (size))
PROBE(void *, calloc, (size_t count, size_t size), (count, size))
PROBE(void *, realloc, (void *pointer, size_t size), (pointer, size))
PROBE(void *, valloc, (size_t size), (size))
PROBE(void *, aligned_alloc, (size_t alignment, size_t size), (alignment, size))
PROBE(int, posix_memalign, (void **pointer, size_t alignment, size_t size), (pointer, alignment, size))
