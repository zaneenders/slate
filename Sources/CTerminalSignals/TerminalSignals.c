#include "CTerminalSignals.h"
#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Signal state requires lock-free atomics");

static const int signals[5] = {SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT};
static struct sigaction saved[5];
static _Atomic unsigned int owned;
static _Atomic unsigned int termination;
static _Atomic unsigned int suspension;

// No Swift, locks, allocation, descriptors, or terminal work in signal context.
static void record_signal(int number) {
  if (number == SIGTSTP) atomic_store_explicit(&suspension, 1, memory_order_relaxed);
  else if (number == SIGCONT) atomic_store_explicit(&suspension, 0, memory_order_relaxed);
  else atomic_store_explicit(&termination, (unsigned int)number, memory_order_relaxed);
}

static struct sigaction action(void) {
  struct sigaction result = {0};
  result.sa_handler = record_signal;
  sigemptyset(&result.sa_mask);
  for (size_t i = 0; i < 5; i++) sigaddset(&result.sa_mask, signals[i]);
  // Interrupt syscalls; the owner notices flags at its next poll boundary.
  result.sa_flags = 0;
  return result;
}

int cli_signals_acquire(void) {
  if (atomic_exchange_explicit(&owned, 1, memory_order_acquire)) return EBUSY;
  atomic_store_explicit(&termination, 0, memory_order_relaxed);
  atomic_store_explicit(&suspension, 0, memory_order_relaxed);
  struct sigaction handler = action();
  for (size_t i = 0; i < 5; i++) {
    if (sigaction(signals[i], &handler, &saved[i]) != 0) {
      int error = errno;
      for (size_t j = 0; j < i; j++) sigaction(signals[j], &saved[j], NULL);
      atomic_store_explicit(&owned, 0, memory_order_release);
      return error;
    }
  }
  return 0;
}

int cli_signals_release(void) {
  int error = 0;
  for (size_t i = 0; i < 5; i++) {
    if (sigaction(signals[i], &saved[i], NULL) != 0 && error == 0) error = errno;
  }
  atomic_store_explicit(&owned, 0, memory_order_release);
  return error;
}

int cli_signals_termination(void) {
  return atomic_load_explicit(&owned, memory_order_relaxed)
    ? (int)atomic_load_explicit(&termination, memory_order_relaxed) : 0;
}

int cli_signals_take_suspend(void) {
  return (int)atomic_exchange_explicit(&suspension, 0, memory_order_relaxed);
}

int cli_signals_suspend(void) {
  if (cli_signals_termination()) return 0;
  struct sigaction stop = {0};
  stop.sa_handler = SIG_DFL;
  sigemptyset(&stop.sa_mask);
  if (sigaction(SIGTSTP, &stop, NULL) != 0) return errno;
  // Native job control: orphaned process groups may ignore SIGTSTP. Resume
  // returns here; the Swift owner then re-enters modes and invalidates its frame.
  int result = raise(SIGTSTP);
  int error = result == 0 ? 0 : errno;
  struct sigaction handler = action();
  if (sigaction(SIGTSTP, &handler, NULL) != 0 && error == 0) error = errno;
  return error;
}
