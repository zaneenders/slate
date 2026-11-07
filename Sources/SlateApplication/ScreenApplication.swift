@_exported public import SlateTerminal

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The result of handling a key. Several redraw requests in one input batch
/// produce one frame; quitting stops delivery of the rest of that batch.
public enum ScreenUpdate: Equatable, Sendable {
  case none
  case redraw
  case quit
}

/// Startup storage and viewport policy. Invalid capacities throw
/// `ScreenApplicationError.screen(.invalidCapacity)` before changing terminal modes.
public struct ScreenApplicationConfiguration: Sendable {
  public enum ViewportOverflow: Sendable {
    /// Render the top-left portion that fits in the startup capacity.
    case clip
    /// Report `ScreenApplicationError.screen(.viewportCapacityExceeded)`.
    case fail
  }

  public let maximumSize: TerminalSize
  public let nodeCapacity: Int
  public let viewportOverflow: ViewportOverflow

  public init(
    maximumSize: TerminalSize = TerminalSize(columns: 240, rows: 80),
    nodeCapacity: Int = LayoutLimits.maximumNodes,
    viewportOverflow: ViewportOverflow = .clip
  ) {
    self.maximumSize = maximumSize
    self.nodeCapacity = nodeCapacity
    self.viewportOverflow = viewportOverflow
  }
}

public enum ScreenApplicationError: Error, Equatable, Sendable {
  case screen(ScreenError)
  case terminal(TerminalError)
  case io(IOError)
  case poll(errno: Int32)
  case disconnected
  case signalSetup(errno: Int32)
  case interrupted(signal: Int32)
}

/// A synchronous terminal application. State belongs to the application;
/// terminal resources and reusable buffers belong to its scoped runner.
///
/// The first frame and physical resizes render automatically. Invalid input
/// sequences are ignored; decoded keys, including Ctrl-C, belong to `handle`.
/// Managed sessions reserve unpasted Ctrl-Z for suspension. Paste has its own callback.
/// Neither callback may retain frame borrows or start another terminal reader.
public protocol ScreenApplication: ~Copyable {
  associatedtype Content: Block
  init()
  static var configuration: ScreenApplicationConfiguration { get }
  // TODO: Why two handle functions?
  mutating func handle(_ key: InputKey) -> ScreenUpdate
  /// Default forwards unmodified keys to `handle(_:)`. Clipboard requests are
  /// prepared synchronously and written after this input batch.
  mutating func handle(_ key: InputKey, modifiers: KeyModifiers, clipboard: inout Clipboard) -> ScreenUpdate
  /// Complete, valid UTF-8, at most 64 KiB. Borrow ends with this callback.
  mutating func paste(_ text: UTF8Span) -> ScreenUpdate
  mutating func pasteRejected(_ error: PasteError) -> ScreenUpdate
  @BlockBuilder borrowing func render(in size: TerminalSize) -> Content
}

extension ScreenApplication where Self: ~Copyable {
  public static var configuration: ScreenApplicationConfiguration { .init() }
  public mutating func handle(_ key: InputKey) -> ScreenUpdate { .none }
  public mutating func handle(_ key: InputKey, modifiers: KeyModifiers, clipboard: inout Clipboard) -> ScreenUpdate {
    modifiers.isEmpty ? handle(key) : .none
  }
  public mutating func paste(_ text: UTF8Span) -> ScreenUpdate { .none }
  public mutating func pasteRejected(_ error: PasteError) -> ScreenUpdate { .none }

  /// Convenience executable entry point. Ignores SIGPIPE process-wide so a
  /// broken output can unwind the terminal scopes before reporting an error.
  public static func main() {
    // Raw mode disables terminal-generated signals, not SIGPIPE from writes to
    // closed pipes or sockets. Keep this process-wide policy at the entry point;
    // it must also cover diagnostics written after terminal scopes unwind.
    _ = signal(SIGPIPE, SIG_IGN)
    do throws(ScreenApplicationError) {
      var application = Self()
      try application.run(signalHandling: .managed)
    } catch {
      if case .interrupted(let number) = error { exit(128 + number) }
      var message = "\(Self.self): \(error)\n"
      if let diagnostics = try? Output(fileDescriptor: STDERR_FILENO) {
        try? message.withUTF8 { buffer throws(IOError) in
          try diagnostics.writeAll(unsafe Span(_unsafeElements: buffer))
        }
      }
      exit(EXIT_FAILURE)  // TODO: Can we have main throw and do swifts error handleing for return not zero?
    }
  }

  /// Runs until `.quit`, EOF, or an error. Both descriptors must be terminals;
  /// originals remain caller-owned. Uses one reader and one display writer.
  /// Signal handling is opt-in for embedding. Normal exit reports restoration errors;
  /// Swift error unwinding makes best-effort restoration attempts.
  ///
  /// Reports typed screen, terminal, I/O, and polling failures.
  /// Resize and lone-Escape deadlines are checked at 50 ms poll boundaries;
  /// callbacks and blocking I/O can extend that interval.
  public mutating func run(
    inputFileDescriptor: Int32 = 0, outputFileDescriptor: Int32 = 1,
    signalHandling: ScreenSignalHandling = .unchanged
  ) throws(ScreenApplicationError) {
    var runner: ScreenRunner

    do throws(ScreenError) {
      runner = try ScreenRunner(configuration: Self.configuration)
    } catch { throw .screen(error) }

    let output: Output

    do throws(IOError) {
      output = try Output(fileDescriptor: outputFileDescriptor)
    } catch { throw .io(error) }

    let actualSize: TerminalSize
    do throws(TerminalError) {
      actualSize = try output.terminalSize()
    } catch { throw .terminal(error) }

    do throws(ScreenError) {
      _ = try runner.viewport(for: actualSize)
    } catch { throw .screen(error) }

    var terminal: Terminal
    do throws(TerminalError) {
      terminal = try Terminal(fileDescriptor: inputFileDescriptor)
    } catch { throw .terminal(error) }

    let signals = try SignalSession(signalHandling)

    while true {
      let number = signals.termination()
      if number != 0 { throw .interrupted(signal: number) }
      let result: ScreenRunResult
      do throws(ScreenApplicationError) {
        result = try session(runner: &runner, terminal: &terminal, output: output, signals: signals)
      } catch {
        let number = signals.termination()
        if number != 0 { throw .interrupted(signal: number) }
        throw error
      }
      // A signal can arrive in the final input callback or during restoration.
      // Preserve its exit status even when that callback also requested quit.
      let pendingTermination = signals.termination()
      if pendingTermination != 0 { throw .interrupted(signal: pendingTermination) }
      switch result {
      case .quit: return
      case .interrupted(let number): throw .interrupted(signal: number)
      case .suspend:
        try signals.suspend()
        runner.resume()
      }
    }
  }

  private mutating func session(
    runner: inout ScreenRunner, terminal: inout Terminal, output: borrowing Output,
    signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> ScreenRunResult {
    let raw: RawMode
    do throws(TerminalError) {
      raw = try terminal.rawMode()
    } catch { throw .terminal(error) }
    let alternate: AlternateScreen
    do throws(IOError) {
      alternate = try output.alternateScreen()
    } catch { throw .io(error) }
    let paste: BracketedPaste
    do throws(IOError) { paste = try output.bracketedPaste() } catch { throw .io(error) }
    let result = try runner.run(
      application: &self, input: raw, output: output, signals: signals)
    do throws(IOError) { try paste.restore() } catch { throw .io(error) }
    do throws(IOError) {
      try alternate.restore()
    } catch { throw .io(error) }
    do throws(TerminalError) {
      try raw.restore()
    } catch { throw .terminal(error) }
    return result
  }
}
