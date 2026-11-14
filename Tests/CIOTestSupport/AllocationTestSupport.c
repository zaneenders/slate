#include "CIOTestSupport.h"

#if defined(__APPLE__) || defined(__linux__)
#include <assert.h>
#include <dlfcn.h>

static _Thread_local void (*begin_probe)(void);
static _Thread_local uint64_t (*end_probe)(void);

int cli_test_prepare_allocation_counter(void) {
  begin_probe = dlsym(RTLD_DEFAULT, "slate_allocation_probe_begin");
  end_probe = dlsym(RTLD_DEFAULT, "slate_allocation_probe_end");
  return begin_probe != NULL && end_probe != NULL;
}

void cli_test_begin_allocation_count(void) {
  assert(begin_probe != NULL);
  begin_probe();
}

uint64_t cli_test_end_allocation_count(void) {
  assert(end_probe != NULL);
  return end_probe();
}
#endif
