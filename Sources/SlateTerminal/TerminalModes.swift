public import SlateUI
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import CSystem
import Glibc
#elseif canImport(Musl)
import CSystem
import Musl
#endif

extension Output {
  /// Queries the output terminal, independently of the input terminal.
  public borrowing func terminalSize() throws(TerminalError) -> TerminalSize {
    var size = winsize()
    guard unsafe ioctl(descriptor.rawValue, UInt(TIOCGWINSZ), &size) == 0 else {
      throw .readSize(errno: errno)
    }
    return TerminalSize(columns: Int(size.ws_col), rows: Int(size.ws_row))
  }

  @_lifetime(borrow self)
  public borrowing func alternateScreen() throws(IOError) -> AlternateScreen {
    try AlternateScreen(output: self)
  }

  @_lifetime(borrow self)
  public borrowing func bracketedPaste() throws(IOError) -> BracketedPaste {
    try BracketedPaste(output: self)
  }

  @_lifetime(borrow self)
  public borrowing func mouseTracking() throws(IOError) -> MouseTracking {
    try MouseTracking(output: self)
  }

  @_lifetime(borrow self)
  public borrowing func graphemeClustering() throws(IOError) -> GraphemeClustering {
    try GraphemeClustering(output: self)
  }

  @_lifetime(borrow self)
  public borrowing func enhancedKeyboard() throws(IOError) -> EnhancedKeyboard {
    try EnhancedKeyboard(output: self)
  }
}

/// Requests Kitty's disambiguated key encoding on supporting terminals. The
/// previous keyboard flags are restored on exit, including errors.
public struct EnhancedKeyboard: ~Copyable, ~Escapable, ~Sendable {
  private var session: TerminalModeSession

  @_lifetime(borrow output)
  init(output: borrowing Output) throws(IOError) {
    session = try TerminalModeSession(output: output, mode: .keyboard)
  }

  public consuming func restore() throws(IOError) { try session.restore() }
}

/// Uses Unicode grapheme widths (DEC mode 2027) on supporting terminals. Saves
/// and restores the previous mode with XTSAVE/XTRESTORE; unsupported terminals
/// ignore the sequences. Do not nest owners of this mode on the same terminal.
/// ScreenApplication owns this scope, including error exits.
public struct GraphemeClustering: ~Copyable, ~Escapable, ~Sendable {
  private var session: TerminalModeSession

  @_lifetime(borrow output)
  init(output: borrowing Output) throws(IOError) {
    session = try TerminalModeSession(output: output, mode: .grapheme)
  }

  public consuming func restore() throws(IOError) { try session.restore() }
}

/// Scoped all-motion tracking (1003) with SGR cell coordinates (1006).
/// Do not nest mouse-mode owners on the same terminal. Destruction disables
/// both modes, including on throwing exits and partially written setup.
public struct MouseTracking: ~Copyable, ~Escapable, ~Sendable {
  private var session: TerminalModeSession

  @_lifetime(borrow output)
  init(output: borrowing Output) throws(IOError) {
    session = try TerminalModeSession(output: output, mode: .mouse)
  }

  /// On failure, retries restoration once and rethrows the original error.
  public consuming func restore() throws(IOError) { try session.restore() }
}

/// Scoped paste framing. Do not nest mode owners on the same terminal.
public struct BracketedPaste: ~Copyable, ~Escapable, ~Sendable {
  private var session: TerminalModeSession

  @_lifetime(borrow output)
  init(output: borrowing Output) throws(IOError) {
    session = try TerminalModeSession(output: output, mode: .paste)
  }

  /// On failure, retries restoration once and rethrows the original error.
  public consuming func restore() throws(IOError) { try session.restore() }
}

/// Enters the alternate screen and hides the cursor. Exit resets style, shows
/// the cursor, and returns to the main screen. Coordinate other output owners.
/// Scope exit and Swift error unwinding perform best-effort cleanup.
public struct AlternateScreen: ~Copyable, ~Escapable, ~Sendable {
  private var session: TerminalModeSession

  @_lifetime(borrow output)
  init(output: borrowing Output) throws(IOError) {
    session = try TerminalModeSession(output: output, mode: .alternate)
  }

  /// On failure, retries restoration once and rethrows the original error.
  public consuming func restore() throws(IOError) { try session.restore() }
}

// ABI visibility forces Swift 6.4.2 to emit metadata referenced by optimized
// destruction of the public noncopyable guards from other targets. Module
// visibility alone works in testable builds but omits it in production builds.
@usableFromInline enum TerminalMode: Sendable {
  case mouse, paste, alternate, grapheme, keyboard

  var sequences: (enable: StaticString, restore: StaticString) {
    switch self {
    case .mouse: ("\u{1b}[?1006h\u{1b}[?1003h", "\u{1b}[?1003l\u{1b}[?1006l")
    case .paste: ("\u{1b}[?2004h", "\u{1b}[?2004l")
    case .alternate: ("\u{1b}[?1049h\u{1b}[?25l\u{1b}[0m", "\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l")
    case .grapheme: ("\u{1b}[?2027s\u{1b}[?2027h", "\u{1b}[?2027r")
    case .keyboard: ("\u{1b}[>1u", "\u{1b}[<u")
    }
  }
}

/// One inline owner per mode, borrowing the output descriptor. Setup failure
/// rolls back once; explicit restoration failure retries once and preserves the
/// first error. Each write uses the existing bounded syscall retry budget.
@usableFromInline struct TerminalModeSession: ~Copyable, ~Escapable, ~Sendable {
  private let descriptor: FileDescriptor
  private let mode: TerminalMode
  private var needsRestore = true

  @_lifetime(borrow output)
  init(output: borrowing Output, mode: TerminalMode) throws(IOError) {
    let sequences = mode.sequences
    do throws(IOError) { try writeStatic(sequences.enable, to: output.descriptor) } catch {
      try? writeStatic(sequences.restore, to: output.descriptor)
      throw error
    }
    descriptor = output.descriptor
    self.mode = mode
  }

  consuming func restore() throws(IOError) {
    let sequence = mode.sequences.restore
    // Finish the consuming operation's cleanup explicitly, including partial
    // escape writes. Destruction must not add a third restoration attempt.
    needsRestore = false
    do throws(IOError) { try writeStatic(sequence, to: descriptor) } catch {
      try? writeStatic(sequence, to: descriptor)
      throw error
    }
  }

  deinit {
    if needsRestore { try? writeStatic(mode.sequences.restore, to: descriptor) }
  }
}
