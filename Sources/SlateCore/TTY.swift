import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private struct RawModeRestoreState {
  var snapshot = termios()
  var snapshotValid = false
}

private let rawModeRestoreState = Mutex(RawModeRestoreState())

// MARK: - Signal-handler-safe restore state

// These globals are read from @convention(c) signal handlers (SIGTERM / SIGHUP)
// which have no actor isolation. They must not be guarded by a mutex: Swift's Mutex
// uses os_unfair_lock / pthread_mutex_t, neither of which is async-signal-safe.
//
// g_signalSafeSnapshot — the original cooked-mode termios.
//   Written exactly once, inside ttyEnterRawOrExit(), after tcgetattr succeeds and
//   before signal handlers are installed. After that it is read-only; no concurrent
//   writes are possible so the plain var is safe without atomics.
//
// g_signalSafeActive — guards against double-restore (normal path + signal).
//   Atomic so the signal handler can check-and-clear it without a lock.
//
// g_restoreBytes — CSI.batchOff + bracketedPasteOff + sgr0 + curShow + altOff,
//   pre-encoded into a ContiguousArray<UInt8> once in ttyEnterRawOrExit() before
//   any signal handlers are installed. The handler reads it via withUnsafeBufferPointer,
//   which is just a pointer load — no ARC, no allocation, no lock at signal time.
private nonisolated(unsafe) var g_signalSafeSnapshot = termios()
private let g_signalSafeActive = Atomic<Bool>(false)
private nonisolated(unsafe) var g_restoreBytes = ContiguousArray<UInt8>()

/// Restores the terminal using only async-signal-safe primitives.
///
/// Called from SIGTERM and SIGHUP signal handlers. Uses `write(2)` and `tcsetattr(2)`,
/// both of which are on the POSIX async-signal-safe list. After restoring (or if the
/// terminal was already restored), resets the signal to its default disposition and
/// re-raises it so the process terminates with the expected exit status / core-dump.
private func ttySignalSafeRestore(_ sig: Int32) {
  if g_signalSafeActive.compareExchange(
    expected: true, desired: false, ordering: .acquiringAndReleasing
  ).exchanged {
    // Write restore sequences directly — write(2) is async-signal-safe.
    unsafe g_restoreBytes.withUnsafeBufferPointer { buf in
      _ = unsafe write(STDOUT_FILENO, buf.baseAddress!, buf.count)
    }
    // Restore saved termios — tcsetattr(2) is async-signal-safe.
    unsafe withUnsafePointer(to: g_signalSafeSnapshot) { snap in
      _ = unsafe tcsetattr(STDIN_FILENO, TCSAFLUSH, snap)
    }
  }
  // Reset to default disposition and re-raise so the process exits (or dumps core)
  // with the expected status. SA_RESETHAND would do this automatically but signal(2)
  // is simpler and sufficient here.
  signal(sig, SIG_DFL)
  raise(sig)
}

// MARK: - stdout write helpers

/// `write(STDOUT_FILENO)` with **EINTR** retry; shared by ``ttyWriteRaw(_:)`` and ``AsyncFrameWriter``.
internal func ttyWriteStdoutAll(_ buffer: UnsafeRawBufferPointer) {
  guard buffer.count > 0, let baseAddress = buffer.baseAddress else { return }
  var sent = 0
  while sent < buffer.count {
    let n = unsafe write(
      STDOUT_FILENO, baseAddress.advanced(by: sent), buffer.count &- sent)
    if n <= 0 {
      guard errno == EINTR else { return }
      continue
    }
    sent += n
  }
}

internal func ttyWriteRaw(_ bytes: borrowing RawSpan) {
  #if compiler(>=6.4)
  bytes.withUnsafeBytes { raw in unsafe ttyWriteStdoutAll(raw) }
  #else
  unsafe bytes.withUnsafeBytes { raw in unsafe ttyWriteStdoutAll(raw) }
  #endif
}

/// Clamped `ioctl(STDOUT_FILENO, TIOCGWINSZ)` (both dimensions ≥ 1).
internal func ioctlStdoutWindowSize(maxCols: Int, maxRows: Int) -> (cols: Int, rows: Int) {
  var ws = winsize()
  let c: Int
  let r: Int
  if unsafe ioctl(STDOUT_FILENO, UInt(Int32(TIOCGWINSZ)), &ws) == 0 {
    let wc = Int(ws.ws_col)
    let wr = Int(ws.ws_row)
    if wc > 0, wr > 0 {
      (c, r) = (wc, wr)
    } else {
      (c, r) = (80, 24)
    }
  } else {
    (c, r) = (80, 24)
  }
  return (min(maxCols, max(1, c)), min(maxRows, max(1, r)))
}

internal enum TTY {
  /// Clamped `ioctl(TIOCGWINSZ)` layout (both dimensions ≥ 1).
  ///
  /// Safe from any isolation; callers that poll for resize typically invoke this off the main actor.
  internal static func windowSize(maxCols: Int = 512, maxRows: Int = 512) -> (cols: Int, rows: Int) {
    ioctlStdoutWindowSize(maxCols: maxCols, maxRows: maxRows)
  }
}

internal func ttyEnterRawOrExit() -> Bool {
  guard isatty(STDIN_FILENO) != 0 else {
    print("error: stdin must be a tty")
    return false
  }
  guard isatty(STDOUT_FILENO) != 0 else {
    print("error: stdout must be a tty")
    return false
  }
  guard
    rawModeRestoreState.withLock({ state in
      unsafe tcgetattr(STDIN_FILENO, &state.snapshot) == 0
    })
  else {
    print("error: tcgetattr failed")
    return false
  }

  var rawMode = rawModeRestoreState.withLock { state in
    state.snapshotValid = true
    // Copy the original cooked-mode termios to the signal-safe global now, while we
    // hold the mutex and before raw mode is applied. The signal handler reads this
    // without a lock — safe because this write happens exactly once, before any
    // signal handlers are installed.
    unsafe g_signalSafeSnapshot = state.snapshot
    return state.snapshot
  }
  unsafe cfmakeraw(&rawMode)
  #if os(macOS)
  rawMode.c_cc.16 /* VMIN */ = 1
  rawMode.c_cc.17 /* VTIME */ = 0
  #else
  rawMode.c_cc.6 /* VMIN */ = 1
  rawMode.c_cc.5 /* VTIME */ = 0
  #endif
  guard unsafe tcsetattr(STDIN_FILENO, TCSAFLUSH, &rawMode) == 0 else {
    print("error: tcsetattr(raw) failed")
    rawModeRestoreState.withLock { state in state.snapshotValid = false }
    return false
  }

  _ = signal(SIGQUIT, SIG_IGN)
  _ = signal(SIGTSTP, SIG_IGN)

  unsafe g_restoreBytes = ContiguousArray(
    (CSI.batchOff + CSI.bracketedPasteOff + CSI.sgr0 + CSI.curShow + CSI.altOff).utf8)

  // Arm SIGTERM and SIGHUP handlers now that raw mode is active.
  // If either signal arrives while the terminal is in raw mode / alt screen, the
  // handler restores the terminal and re-raises with the default disposition so
  // the process exits with the correct status.
  g_signalSafeActive.store(true, ordering: .releasing)
  _ = signal(SIGTERM) { sig in ttySignalSafeRestore(sig) }
  _ = signal(SIGHUP) { sig in ttySignalSafeRestore(sig) }

  return true
}

internal func ttyRestoreSaved() {
  // Disarm the signal-handler path before doing the normal restore so the two
  // paths cannot run concurrently. If a signal fires in the narrow window after
  // g_signalSafeActive is cleared but before signal(SIG_DFL) is called, the
  // handler will still fire but immediately re-raise (g_signalSafeActive == false
  // causes the restore block to be skipped), which is correct — the terminal is
  // about to be restored here anyway.
  g_signalSafeActive.store(false, ordering: .releasing)
  _ = signal(SIGTERM, SIG_DFL)
  _ = signal(SIGHUP, SIG_DFL)
  _ = signal(SIGQUIT, SIG_DFL)
  _ = signal(SIGTSTP, SIG_DFL)

  do {
    // Disable bracketed paste before leaving the alt screen so the user's regular shell
    // doesn't inherit it (matches the `bracketedPasteOn` emitted by ``writeRedrawBootstrapCSI``).
    var tail =
      CSI.batchOff + CSI.bracketedPasteOff + CSI.sgr0 + CSI.curShow + CSI.altOff
    tail.withUTF8 { unsafe ttyWriteRaw($0.span.bytes) }
  }
  rawModeRestoreState.withLock { state in
    guard state.snapshotValid else { return }
    state.snapshotValid = false
    _ = unsafe tcsetattr(STDIN_FILENO, TCSAFLUSH, &state.snapshot)
  }
}
