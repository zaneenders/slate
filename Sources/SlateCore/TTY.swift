#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@MainActor
internal enum GlobalTTY {
  static var snapshot = termios()
  static var snapshotValid = false
}

@MainActor
internal func ttyWriteRaw(_ bytes: borrowing RawSpan) {
  func flush(_ buffer: UnsafeRawBufferPointer) {
    var sent = 0
    while sent < buffer.count {
      let n = unsafe write(
        STDOUT_FILENO, buffer.baseAddress!.advanced(by: sent), buffer.count &- sent)
      if n <= 0 {
        guard errno == EINTR else { return }
        continue
      }
      sent += n
    }
  }
  #if compiler(>=6.4)
  bytes.withUnsafeBytes(flush)
  #else
  unsafe bytes.withUnsafeBytes(flush)
  #endif
}

/// Clamped `ioctl(STDOUT_FILENO, TIOCGWINSZ)` (both dimensions ≥ 1). Shared by ``TTY/windowSize()`` and ``TTYPoll/windowSize()``.
internal nonisolated func ioctlStdoutWindowSize(maxCols: Int, maxRows: Int) -> (cols: Int, rows: Int) {
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

@MainActor
internal enum TTY {
  /// Clamped `ioctl(TIOCGWINSZ)` layout (both dimensions ≥ 1).
  internal static func windowSize(maxCols: Int = 512, maxRows: Int = 512) -> (cols: Int, rows: Int) {
    ioctlStdoutWindowSize(maxCols: maxCols, maxRows: maxRows)
  }
}

/// Off-main ``ioctl(TIOCGWINSZ)`` for background tasks (e.g. terminal resize polling without GCD).
internal enum TTYPoll {
  nonisolated static func windowSize(maxCols: Int = 512, maxRows: Int = 512) -> (cols: Int, rows: Int) {
    ioctlStdoutWindowSize(maxCols: maxCols, maxRows: maxRows)
  }
}

@MainActor
internal func ttyEnterRawOrExit() -> Bool {
  guard isatty(STDIN_FILENO) != 0 else {
    print("error: stdin must be a tty")
    return false
  }
  guard isatty(STDOUT_FILENO) != 0 else {
    print("error: stdout must be a tty")
    return false
  }
  guard unsafe tcgetattr(STDIN_FILENO, &GlobalTTY.snapshot) == 0 else {
    print("error: tcgetattr failed")
    return false
  }
  GlobalTTY.snapshotValid = true

  var rawMode = GlobalTTY.snapshot
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
    GlobalTTY.snapshotValid = false
    return false
  }
  _ = signal(SIGQUIT, SIG_IGN)
  _ = signal(SIGTSTP, SIG_IGN)
  return true
}

@MainActor
internal func ttyRestoreSaved() {
  _ = signal(SIGQUIT, SIG_DFL)
  _ = signal(SIGTSTP, SIG_DFL)
  do {
    var tail = CSI.batchOff + CSI.sgr0 + CSI.curShow + CSI.altOff
    tail.withUTF8 { unsafe ttyWriteRaw($0.span.bytes) }
  }
  guard GlobalTTY.snapshotValid else { return }
  GlobalTTY.snapshotValid = false
  _ = unsafe tcsetattr(STDIN_FILENO, TCSAFLUSH, &GlobalTTY.snapshot)
}
