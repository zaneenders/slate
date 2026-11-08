import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Slate terminal support requires Darwin, Glibc, or Musl.")
#endif

public enum TerminalError: Error, Equatable, Sendable {
  case duplicateDescriptor(errno: Int32)
  case readAttributes(errno: Int32)
  case enableRawMode(errno: Int32)
  case restoreAttributes(errno: Int32)
  case readSize(errno: Int32)
}

/// The caller retains ownership of the original descriptor. Terminal attributes
/// are shared by all descriptors for the same terminal; avoid changing them
/// through another owner while a raw-mode guard is active.
/// The private duplicate uses a descriptor >= 3, preserving closed standard streams.
public struct Terminal: ~Copyable, ~Sendable {
  fileprivate let descriptor: FileDescriptor

  public init(fileDescriptor: Int32 = 0) throws(TerminalError) {
    let duplicate: FileDescriptor
    do { duplicate = try duplicateDescriptor(fileDescriptor) } catch {
      throw .duplicateDescriptor(errno: error.rawValue)
    }

    var attributes = termios()
    let error = readAttributes(duplicate.rawValue, into: &attributes)
    guard error == 0 else {
      try? duplicate.close()
      throw .readAttributes(errno: error)
    }
    descriptor = duplicate
  }

  @_lifetime(&self)
  public mutating func rawMode() throws(TerminalError) -> RawMode {
    try RawMode(terminal: &self)
  }

  /// Reads through the owned descriptor using the terminal's current settings.
  /// With VMIN = 0, zero can mean no input or a timeout rather than EOF.
  /// While a raw-mode guard is alive, use `RawMode.read(into:)` instead.
  /// See `Input.read(into:)` for buffer, EOF, and error behavior.
  public borrowing func read(into buffer: consuming MutableSpan<UInt8>) throws(IOError) -> Int {
    try readBytes(from: descriptor, into: consume buffer)
  }

  deinit {
    // Do not retry close after EINTR: the descriptor may already be closed.
    try? descriptor.close()
  }
}

/// Destruction restores the saved attributes on a best-effort basis, including
/// during error unwinding. Call `restore()` to observe restoration errors.
public struct RawMode: ~Copyable, ~Escapable, ~Sendable {
  // The screen runner polls this same owned duplicate that read(into:) uses.
  private let descriptor: FileDescriptor
  package var rawDescriptor: Int32 { descriptor.rawValue }
  private let savedAttributes: termios
  private var needsRestore = true

  @_lifetime(&terminal)
  fileprivate init(terminal: inout Terminal) throws(TerminalError) {
    let descriptor = terminal.descriptor
    var saved = termios()
    let readError = readAttributes(descriptor.rawValue, into: &saved)
    guard readError == 0 else {
      throw .readAttributes(errno: readError)
    }

    var raw = saved
    unsafe cfmakeraw(&raw)
    // c_cc is imported as a tuple.
    withUnsafeMutableBytes(of: &raw.c_cc) { characters in
      unsafe characters[Int(VMIN)] = 1
      unsafe characters[Int(VTIME)] = 0
    }

    let setError = applyAttributes(descriptor.rawValue, from: &raw)
    guard setError == 0 else {
      // A failed tcsetattr may have changed a subset of the attributes.
      _ = applyAttributes(descriptor.rawValue, from: &saved)
      throw .enableRawMode(errno: setError)
    }
    self.descriptor = descriptor
    savedAttributes = saved
  }

  /// Reads through the borrowed terminal's owned descriptor in raw mode.
  /// See `Input.read(into:)` for buffer, EOF, and error behavior.
  public borrowing func read(into buffer: consuming MutableSpan<UInt8>) throws(IOError) -> Int {
    try readBytes(from: descriptor, into: consume buffer)
  }

  /// If restoration fails, destruction makes one further best-effort attempt.
  public consuming func restore() throws(TerminalError) {
    var saved = savedAttributes
    let error = applyAttributes(descriptor.rawValue, from: &saved)
    guard error == 0 else {
      throw .restoreAttributes(errno: error)
    }
    needsRestore = false
  }

  deinit {
    if needsRestore {
      var saved = savedAttributes
      _ = applyAttributes(descriptor.rawValue, from: &saved)
    }
  }
}

private func readAttributes(_ descriptor: Int32, into attributes: inout termios) -> Int32 {
  unsafe tcgetattr(descriptor, &attributes) == 0 ? 0 : errno
}

private func applyAttributes(_ descriptor: Int32, from attributes: inout termios) -> Int32 {
  // Preserve queued input across mode changes.
  var retries = SystemCallRetryBudget()
  while unsafe tcsetattr(descriptor, TCSANOW, &attributes) == -1 {
    let error = errno
    if !retries.retry(after: error) { return error }
  }
  return 0
}
