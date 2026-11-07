public import SlateUI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension Output {
  /// Queries the output terminal, independently of the input terminal.
  public borrowing func terminalSize() throws(TerminalError) -> TerminalSize {
    var size = winsize()
    var retries = SystemCallRetryBudget()
    while unsafe ioctl(descriptor, UInt(TIOCGWINSZ), &size) == -1 {
      let error = errno
      if !retries.retry(after: error) { throw .readSize(errno: error) }
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
}

/// Scoped all-motion tracking (1003) with SGR cell coordinates (1006).
/// Do not nest mouse-mode owners on the same terminal. Destruction disables
/// both modes, including on throwing exits and partially written setup.
public struct MouseTracking: ~Copyable, ~Escapable {
  private let descriptor: Int32
  private var needsRestore = true

  @_lifetime(borrow output)
  init(output: borrowing Output) throws(IOError) {
    do throws(IOError) { try writeStatic("\u{1b}[?1006h\u{1b}[?1003h", to: output.descriptor) } catch {
      try? writeStatic("\u{1b}[?1003l\u{1b}[?1006l", to: output.descriptor)
      throw error
    }
    descriptor = output.descriptor
  }

  public consuming func restore() throws(IOError) {
    do throws(IOError) { try writeStatic("\u{1b}[?1003l\u{1b}[?1006l", to: descriptor) } catch {
      try? writeStatic("\u{1b}[?1003l\u{1b}[?1006l", to: descriptor)
      needsRestore = false
      throw error
    }
    needsRestore = false
  }

  deinit {
    if needsRestore { try? writeStatic("\u{1b}[?1003l\u{1b}[?1006l", to: descriptor) }
  }
}

/// Scoped paste framing. Do not nest mode owners on the same terminal.
public struct BracketedPaste: ~Copyable, ~Escapable {
  private let descriptor: Int32
  private var needsRestore = true

  @_lifetime(borrow output)
  init(output: borrowing Output) throws(IOError) {
    do throws(IOError) { try writeStatic("\u{1b}[?2004h", to: output.descriptor) } catch {
      try? writeStatic("\u{1b}[?2004l", to: output.descriptor)
      throw error
    }
    descriptor = output.descriptor
  }

  /// On failure, makes one best-effort fallback and rethrows the original error.
  public consuming func restore() throws(IOError) {
    do throws(IOError) {
      try writeStatic("\u{1b}[?2004l", to: descriptor)
    } catch {
      // Complete cleanup before rethrowing from this consuming operation,
      // including when the first write stopped partway through the sequence.
      try? writeStatic("\u{1b}[?2004l", to: descriptor)
      needsRestore = false
      throw error
    }
    needsRestore = false
  }

  deinit {
    if needsRestore { try? writeStatic("\u{1b}[?2004l", to: descriptor) }
  }
}

/// Enters the alternate screen and hides the cursor. Exit resets style, shows
/// the cursor, and returns to the main screen. Coordinate other output owners.
/// Scope exit and Swift error unwinding perform best-effort cleanup.
public struct AlternateScreen: ~Copyable, ~Escapable {
  private let descriptor: Int32
  private var needsRestore = true

  @_lifetime(borrow output)
  init(output: borrowing Output) throws(IOError) {
    do throws(IOError) {
      try writeStatic("\u{1b}[?1049h\u{1b}[?25l\u{1b}[0m", to: output.descriptor)
    } catch {
      // A failed write may have already enabled either mode.
      try? writeStatic("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l", to: output.descriptor)
      throw error
    }
    descriptor = output.descriptor
  }

  public consuming func restore() throws(IOError) {
    do throws(IOError) {
      try writeStatic("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l", to: descriptor)
    } catch {
      // Complete the consuming operation's one best-effort fallback explicitly,
      // including when the first write stopped partway through an escape code.
      try? writeStatic("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l", to: descriptor)
      needsRestore = false
      throw error
    }
    needsRestore = false
  }

  deinit {
    if needsRestore { try? writeStatic("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l", to: descriptor) }
  }
}
