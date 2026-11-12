// Opt-in Darwin interposer, built as a separate dylib by check-render-allocations.sh.
// Interposition from the test executable itself does not intercept its allocations.
// Counts outermost allocation API calls on the calling thread, including failed
// attempts through the entry points below. Direct zone-function calls, mmap,
// custom allocators, and allocations on other threads are outside this probe.
// No production target links this file.
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

// TLS lookup itself can allocate during process/thread startup, recursively
// entering calloc. An atomic owner avoids TLS inside allocator replacements.
// Only one synchronous measured region may be active in the process.
static _Atomic(pthread_t) owner;
static bool inside_allocator;
static uint64_t calls;

void slate_allocation_probe_begin(void) {
  pthread_t expected = NULL;
  bool claimed = atomic_compare_exchange_strong(&owner, &expected, pthread_self());
  if (!claimed) abort();
  calls = 0;
}

uint64_t slate_allocation_probe_end(void) {
  if (atomic_load(&owner) != pthread_self()) abort();
  uint64_t result = calls;
  atomic_store(&owner, NULL);
  return result;
}

// The replacement image calls the original symbols. Temporarily disabling the
// counter avoids double-counting nested allocator entry points in other images.
#define PROBE(result_type, name, parameters, arguments) \
  static result_type probe_##name parameters { \
    pthread_t active = atomic_load(&owner); \
    bool record = active != NULL && active == pthread_self() && !inside_allocator; \
    if (record) { \
      if (calls != UINT64_MAX) calls++; \
      inside_allocator = true; \
    } \
    result_type result = name arguments; \
    if (record) inside_allocator = false; \
    return result; \
  } \
  __attribute__((used)) static const struct { \
    const void *replacement; \
    const void *original; \
  } interpose_##name __attribute__((section("__DATA,__interpose,interposing"))) = { \
    (const void *)&probe_##name, (const void *)&name \
  };

PROBE(void *, malloc, (size_t size), (size))
PROBE(void *, calloc, (size_t count, size_t size), (count, size))
PROBE(void *, realloc, (void *pointer, size_t size), (pointer, size))
PROBE(void *, valloc, (size_t size), (size))
PROBE(void *, aligned_alloc, (size_t alignment, size_t size), (alignment, size))
PROBE(int, posix_memalign, (void **pointer, size_t alignment, size_t size), (pointer, alignment, size))
PROBE(void *, malloc_zone_malloc, (malloc_zone_t *zone, size_t size), (zone, size))
PROBE(void *, malloc_zone_calloc, (malloc_zone_t *zone, size_t count, size_t size), (zone, count, size))
PROBE(void *, malloc_zone_realloc, (malloc_zone_t *zone, void *pointer, size_t size), (zone, pointer, size))
PROBE(void *, malloc_zone_valloc, (malloc_zone_t *zone, size_t size), (zone, size))
PROBE(void *, malloc_zone_memalign, (malloc_zone_t *zone, size_t alignment, size_t size), (zone, alignment, size))

// The current Swift runtime and Clang can use typed allocation entry points.
PROBE(void *, malloc_type_malloc, (size_t size, malloc_type_id_t type), (size, type))
PROBE(void *, malloc_type_calloc, (size_t count, size_t size, malloc_type_id_t type), (count, size, type))
PROBE(void *, malloc_type_realloc, (void *pointer, size_t size, malloc_type_id_t type), (pointer, size, type))
PROBE(void *, malloc_type_valloc, (size_t size, malloc_type_id_t type), (size, type))
PROBE(void *, malloc_type_aligned_alloc, (size_t alignment, size_t size, malloc_type_id_t type), (alignment, size, type))
PROBE(int, malloc_type_posix_memalign,
  (void **pointer, size_t alignment, size_t size, malloc_type_id_t type), (pointer, alignment, size, type))
PROBE(void *, malloc_type_zone_malloc, (malloc_zone_t *zone, size_t size, malloc_type_id_t type), (zone, size, type))
PROBE(void *, malloc_type_zone_calloc,
  (malloc_zone_t *zone, size_t count, size_t size, malloc_type_id_t type), (zone, count, size, type))
PROBE(void *, malloc_type_zone_realloc,
  (malloc_zone_t *zone, void *pointer, size_t size, malloc_type_id_t type), (zone, pointer, size, type))
PROBE(void *, malloc_type_zone_valloc, (malloc_zone_t *zone, size_t size, malloc_type_id_t type), (zone, size, type))
PROBE(void *, malloc_type_zone_memalign,
  (malloc_zone_t *zone, size_t alignment, size_t size, malloc_type_id_t type), (zone, alignment, size, type))
