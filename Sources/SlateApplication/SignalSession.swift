import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum ScreenSignalHandling: Sendable {
  /// Embedding applications retain their signal policy.
  case unchanged
  /// One process-wide owner; restores previous dispositions on all scoped exits.
  /// Catches asynchronous termination requests and ignores job-control stops
  /// and SIGPIPE. Masks asynchronous signals on the calling thread during
  /// terminal setup/teardown, restoring its original mask before returning.
  /// Synchronous fault and child/realtime signal dispositions remain owned
  /// by the host. SIGKILL and SIGSTOP cannot be intercepted.
  case managed
}

struct SignalSession: ~Copyable, ~Sendable {
  let enabled: Bool
  private let savedActions: InlineArray<19, sigaction>
  private let savedMask: sigset_t

  init(_ policy: ScreenSignalHandling) throws(ScreenApplicationError) {
    var saved = InlineArray<19, sigaction>(repeating: sigaction())
    var previousMask = sigset_t()
    if policy == .managed {
      guard !signalState.owned.exchange(true, ordering: .acquiring) else {
        throw .signalSetup(errno: EBUSY)
      }
      var mask = criticalSignalMask()
      let maskError = unsafe pthread_sigmask(SIG_BLOCK, &mask, &previousMask)
      guard maskError == 0 else {
        signalState.owned.store(false, ordering: .releasing)
        throw .signalSetup(errno: maskError)
      }
      // Finish lazy global initialization before publishing the handler. These
      // process-lifetime atomics are never destroyed or replaced between owners.
      signalState.termination.store(0, ordering: .relaxed)
      if unsafe signalHandlerState == nil {
        // This points into process-lifetime global storage, not a temporary or
        // session borrow. Publish once before installing any callback, then
        // never change it. Signal context must not call a lazy global accessor.
        withUnsafePointer(to: signalState) { pointer in unsafe signalHandlerState = pointer }
      }
      for index in managedSignals.indices {
        var handler = signalAction(for: managedSignals[index])
        var previous = sigaction()
        if unsafe sigaction(managedSignals[index], &handler, &previous) != 0 {
          let error = errno
          restoreSignalActions(saved, count: index)
          signalState.owned.store(false, ordering: .releasing)
          _ = unsafe pthread_sigmask(SIG_SETMASK, &previousMask, nil)
          throw .signalSetup(errno: error)
        }
        saved[index] = previous
      }
    }
    enabled = policy == .managed
    savedActions = saved
    savedMask = previousMask
  }

  /// Unblocks signals only once terminal setup is complete, or after teardown
  /// has finished. Pending signals reach our handlers before old dispositions
  /// are restored. This owner and the synchronous runner stay on one thread.
  borrowing func resumeDelivery() throws(ScreenApplicationError) {
    guard enabled else { return }
    var mask = savedMask
    let error = unsafe pthread_sigmask(SIG_SETMASK, &mask, nil)
    guard error == 0 else { throw .signalSetup(errno: error) }
  }

  /// Protect every mode guard's explicit restoration and error-unwinding path.
  /// On other threads the process-wide handlers still only latch termination.
  borrowing func protectTeardown() {
    guard enabled else { return }
    var mask = criticalSignalMask()
    _ = unsafe pthread_sigmask(SIG_BLOCK, &mask, nil)
  }

  borrowing func termination() -> Int32 {
    enabled ? signalState.termination.load(ordering: .relaxed) : 0
  }

  deinit {
    if enabled {
      // Deliver pending requests while our handlers still own their signals.
      // Terminal guards have already restored their state at this point.
      try? resumeDelivery()
      restoreSignalActions(savedActions, count: managedSignals.count)
      signalState.owned.store(false, ordering: .releasing)
    }
  }
}

#if os(Linux)
private let managedSignals: InlineArray<19, Int32> = [
  SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGALRM, SIGUSR1, SIGUSR2, SIGVTALRM,
  SIGPROF, SIGXCPU, SIGXFSZ, SIGIO, SIGPWR,
  SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGCONT, SIGWINCH
]
#else
private let managedSignals: InlineArray<18, Int32> = [
  SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGALRM, SIGUSR1, SIGUSR2, SIGVTALRM,
  SIGPROF, SIGXCPU, SIGXFSZ, SIGIO,
  SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGCONT, SIGWINCH
]
#endif

/// One owner and one coalescing termination flag, with no queue or capacity
/// growth. Each session saves its dispositions inline. Only the
/// termination flag is accessed in signal context; 32-bit atomics are lock-free.
private struct SignalState: ~Copyable, Sendable {
  let owned = Atomic(false)
  let termination = Atomic<Int32>(0)

  // Verify that the callback body cannot allocate, lock, or perform ARC. Global
  // initialization is forced by acquisition before any handler is installed.
  @_noLocks
  borrowing func record(_ number: Int32) {
    // A later signal must not replace the request that started unwinding.
    _ = termination.compareExchange(expected: 0, desired: number, ordering: .relaxed)
  }
}

private let signalState = SignalState()
// A single publication before handlers are installed; read-only thereafter.
// Avoid debug-mode exclusivity runtime calls from the signal entry point too.
@exclusivity(unchecked)
nonisolated(unsafe) private var signalHandlerState: UnsafePointer<SignalState>? = nil

@c(slate_record_signal)
@_noLocks
private func recordSignal(_ number: Int32) {
  if let state = unsafe signalHandlerState { unsafe state.pointee.record(number) }
}

private func signalAction(for number: Int32) -> sigaction {
  var result = sigaction()
  let ignored =
    number == SIGTSTP || number == SIGTTIN || number == SIGTTOU
    || number == SIGPIPE || number == SIGCONT || number == SIGWINCH
  #if canImport(Darwin)
  unsafe result.__sigaction_u.__sa_handler = ignored ? SIG_IGN : recordSignal
  #elseif canImport(Musl)
  unsafe result.__sa_handler.sa_handler = ignored ? SIG_IGN : recordSignal
  #else
  unsafe result.__sigaction_handler.sa_handler = ignored ? SIG_IGN : recordSignal
  #endif
  precondition(unsafe sigemptyset(&result.sa_mask) == 0)
  for number in managedSignals {
    precondition(unsafe sigaddset(&result.sa_mask, number) == 0)
  }
  // Interrupt syscalls; the owner notices flags at its next poll boundary.
  result.sa_flags = 0
  return result
}

private func restoreSignalActions(_ saved: borrowing InlineArray<19, sigaction>, count: Int) {
  precondition(count >= 0 && count <= managedSignals.count)
  for index in 0..<count {
    var previous = saved[index]
    _ = unsafe sigaction(managedSignals[index], &previous, nil)
  }
}

/// Follows swift-subprocess's _subprocess_make_critical_mask: defer asynchronous
/// delivery while preserving synchronous faults and uncatchable signals. Masking
/// fault signals could interfere with Swift's runtime crash handlers or return
/// execution to a faulting instruction. No mask changes occur in signal context.
private func criticalSignalMask() -> sigset_t {
  var mask = sigset_t()
  precondition(unsafe sigfillset(&mask) == 0)
  let faults: InlineArray<9, Int32> = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGKILL, SIGSEGV, SIGSTOP, SIGSYS, SIGTRAP]
  for index in faults.indices {
    precondition(unsafe sigdelset(&mask, faults[index]) == 0)
  }
  #if canImport(Darwin)
  precondition(unsafe sigdelset(&mask, SIGEMT) == 0)
  #endif
  return mask
}

enum ScreenRunResult {
  case quit
  case interrupted(Int32)
}
