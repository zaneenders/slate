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
  /// SIGTSTP is ignored for the duration of the session.
  case managed
}

struct SignalSession: ~Copyable {
  let enabled: Bool
  private let savedActions: InlineArray<5, sigaction>

  init(_ policy: ScreenSignalHandling) throws(ScreenApplicationError) {
    var saved = InlineArray<5, sigaction>(repeating: sigaction())
    if policy == .managed {
      guard !signalState.owned.exchange(true, ordering: .acquiring) else {
        throw .signalSetup(errno: EBUSY)
      }
      // Finish lazy global initialization before publishing the handler. These
      // process-lifetime atomics are never destroyed or replaced between owners.
      signalState.termination.store(0, ordering: .relaxed)
      for index in managedSignals.indices {
        var handler = signalAction(for: managedSignals[index])
        var previous = sigaction()
        if unsafe sigaction(managedSignals[index], &handler, &previous) != 0 {
          let error = errno
          restoreSignalActions(saved, count: index)
          signalState.owned.store(false, ordering: .releasing)
          throw .signalSetup(errno: error)
        }
        saved[index] = previous
      }
    }
    enabled = policy == .managed
    savedActions = saved
  }

  borrowing func termination() -> Int32 {
    enabled ? signalState.termination.load(ordering: .relaxed) : 0
  }

  deinit {
    if enabled {
      restoreSignalActions(savedActions, count: managedSignals.count)
      signalState.owned.store(false, ordering: .releasing)
    }
  }
}

private let managedSignals: InlineArray<5, Int32> = [SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT]

/// One owner and one coalescing termination flag, with no queue or capacity
/// growth. Each session saves exactly five dispositions inline. Only the
/// termination flag is accessed in signal context; 32-bit atomics are lock-free.
private struct SignalState: ~Copyable, Sendable {
  let owned = Atomic(false)
  let termination = Atomic<Int32>(0)

  // Verify that the callback body cannot allocate, lock, or perform ARC. Global
  // initialization is forced by acquisition before any handler is installed.
  @_noLocks
  borrowing func record(_ number: Int32) {
    if number == SIGINT || number == SIGTERM || number == SIGHUP {
      termination.store(number, ordering: .relaxed)
    }
  }
}

private let signalState = SignalState()

@c(slate_record_signal)
private func recordSignal(_ number: Int32) {
  signalState.record(number)
}

private func signalAction(for number: Int32) -> sigaction {
  var result = sigaction()
  #if canImport(Darwin)
  unsafe result.__sigaction_u.__sa_handler = number == SIGTSTP ? SIG_IGN : recordSignal
  #elseif canImport(Musl)
  unsafe result.__sa_handler.sa_handler = number == SIGTSTP ? SIG_IGN : recordSignal
  #else
  unsafe result.__sigaction_handler.sa_handler = number == SIGTSTP ? SIG_IGN : recordSignal
  #endif
  precondition(unsafe sigemptyset(&result.sa_mask) == 0)
  for number in managedSignals {
    precondition(unsafe sigaddset(&result.sa_mask, number) == 0)
  }
  // Interrupt syscalls; the owner notices flags at its next poll boundary.
  result.sa_flags = 0
  return result
}

private func restoreSignalActions(_ saved: borrowing InlineArray<5, sigaction>, count: Int) {
  precondition(count >= 0 && count <= managedSignals.count)
  for index in 0..<count {
    var previous = saved[index]
    _ = unsafe sigaction(managedSignals[index], &previous, nil)
  }
}

enum ScreenRunResult {
  case quit
  case interrupted(Int32)
}
