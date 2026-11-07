import CTerminalSignals

public enum ScreenSignalHandling: Sendable {
  /// Embedding applications retain their signal policy.
  case unchanged
  /// One process-wide owner; restores previous dispositions on all scoped exits.
  case managed
}

struct SignalSession: ~Copyable {
  let enabled: Bool

  init(_ policy: ScreenSignalHandling) throws(ScreenApplicationError) {
    if policy == .managed {
      let error = cli_signals_acquire()
      guard error == 0 else { throw .signalSetup(errno: error) }
    }
    enabled = policy == .managed
  }

  borrowing func termination() -> Int32 { enabled ? cli_signals_termination() : 0 }
  borrowing func shouldSuspend() -> Bool { enabled && cli_signals_take_suspend() != 0 }

  borrowing func suspend() throws(ScreenApplicationError) {
    precondition(enabled)
    let error = cli_signals_suspend()
    guard error == 0 else { throw .signalSetup(errno: error) }
  }

  deinit { if enabled { _ = cli_signals_release() } }
}

enum ScreenRunResult {
  case quit, suspend
  case interrupted(Int32)
}
