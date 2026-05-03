import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - TTY restore state (global, because ~Copyable deinit cannot handle partial failure)

private struct RawModeRestoreState {
  var snapshot = termios()
  var snapshotValid = false
}

private let rawModeRestoreState = Mutex(RawModeRestoreState())

// MARK: - Low-level write

/// `write(STDOUT_FILENO)` with **EINTR** retry.
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

// MARK: - Window size

/// Clamped `ioctl(STDOUT_FILENO, TIOCGWINSZ)` (both dimensions ≥ 1).
internal func ioctlStdoutWindowSize(maxCols: Int = 512, maxRows: Int = 512) -> (cols: Int, rows: Int) {
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

// MARK: - Raw mode

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
  return true
}

internal func ttyRestoreSaved() {
  _ = signal(SIGQUIT, SIG_DFL)
  _ = signal(SIGTSTP, SIG_DFL)
  rawModeRestoreState.withLock { state in
    guard state.snapshotValid else { return }
    state.snapshotValid = false
    _ = unsafe tcsetattr(STDIN_FILENO, TCSAFLUSH, &state.snapshot)
  }
}
