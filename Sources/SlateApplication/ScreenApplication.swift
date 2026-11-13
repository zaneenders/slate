@_exported public import SlateTerminal

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The result of handling an event. Several redraw requests in one input batch
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

  public static let defaultMaximumPasteBytes = 1_048_576
  public static let maximumPasteBytesLimit = 64 * 1_048_576

  public let maximumSize: TerminalSize
  public let viewportOverflow: ViewportOverflow
  /// Own scoped SGR mouse tracking for each active session, including resume.
  public let mouseTracking: Bool
  public let capabilities: TerminalCapabilities
  /// Maximum bracketed-paste payload retained in memory. Oversized pastes are
  /// consumed through their terminator and reported as `.pasteRejected(.tooLarge)`.
  public let maximumPasteBytes: Int

  public init(
    maximumSize: TerminalSize = TerminalSize(columns: 240, rows: 80),
    viewportOverflow: ViewportOverflow = .clip,
    mouseTracking: Bool = false,
    capabilities: TerminalCapabilities = .init(),
    maximumPasteBytes: Int = ScreenApplicationConfiguration.defaultMaximumPasteBytes
  ) {
    self.maximumSize = maximumSize
    self.viewportOverflow = viewportOverflow
    self.mouseTracking = mouseTracking
    self.capabilities = capabilities
    self.maximumPasteBytes = maximumPasteBytes
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
  case invalidTickInterval
}

/// A synchronous terminal application. State belongs to the application;
/// terminal resources and reusable buffers belong to its scoped runner.
///
/// The first frame and physical resizes render automatically. Invalid input
/// sequences are ignored; decoded input, including Ctrl-C, belongs to `event`.
/// Managed sessions reserve unpasted Ctrl-Z for suspension. Event callbacks may
/// not retain frame/paste borrows or start another terminal reader.
public protocol ScreenApplication: ~Copyable {
  associatedtype Content: Block
  init()
  static var configuration: ScreenApplicationConfiguration { get }
  /// Interval between timed events. Defaults to 50 ms; nil disables ticks.
  /// Intervals must be positive or run throws `.invalidTickInterval`.
  /// Changes restart the interval. Late ticks are skipped, never queued.
  /// Polling rounds up to whole milliseconds; callbacks and I/O can delay delivery.
  var tickInterval: Duration? { get }
  /// Whether another bounded work step can run without waiting for input.
  /// Default is false. The runner presents the first frame before doing work.
  var hasPendingWork: Bool { get }
  /// Performs one synchronous, application-bounded batch after checking input.
  /// Return `.redraw` when progress should be presented or `.quit` to stop.
  /// Do not retain frame borrows or start another terminal reader here.
  mutating func performPendingWork() -> ScreenUpdate
  /// Receives ticks, keys, mouse input, complete or empty pastes, and paste failures.
  /// Default returns `.none`. Copy requests are prepared synchronously and written
  /// after this input batch.
  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate
  @BlockBuilder borrowing func render(in size: TerminalSize) -> Content
  /// Draws after block layout, before presentation. The frame cannot escape.
  /// Use this for application-owned editors, charts, or other custom views.
  borrowing func paint(in frame: inout Frame)
}

extension ScreenApplication where Self: ~Copyable {
  public static var configuration: ScreenApplicationConfiguration { .init() }
  public var tickInterval: Duration? { .milliseconds(50) }
  public var hasPendingWork: Bool { false }
  public mutating func performPendingWork() -> ScreenUpdate { .none }
  public mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    .none
  }
  public borrowing func paint(in frame: inout Frame) {}

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
      let message = "\(Self.self): \(error)\n"
      if let diagnostics = try? Output(fileDescriptor: STDERR_FILENO) {
        try? diagnostics.writeAll(message.utf8Span.span)
      }
      // Uncaught errors from a throwing main trap; expected failures exit normally.
      exit(EXIT_FAILURE)
    }
  }

  /// Runs until `.quit`, EOF, or an error. Both descriptors must be terminals;
  /// originals remain caller-owned. Uses one reader and one display writer.
  /// Signal handling is opt-in for embedding. Normal exit reports restoration errors;
  /// Swift error unwinding makes best-effort restoration attempts.
  ///
  /// Reports typed screen, terminal, I/O, and polling failures.
  /// Resize and lone-Escape checks use a poll timeout of at most 50 ms;
  /// callbacks and blocking I/O can extend that interval.
  public mutating func run(
    inputFileDescriptor: Int32 = 0, outputFileDescriptor: Int32 = 1,
    signalHandling: ScreenSignalHandling = .unchanged
  ) throws(ScreenApplicationError) {
    if let tickInterval, tickInterval <= .zero { throw .invalidTickInterval }
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
    let result = try runUnicodeSession(runner: &runner, input: raw, output: output, signals: signals)
    do throws(IOError) { try paste.restore() } catch { throw .io(error) }
    do throws(IOError) {
      try alternate.restore()
    } catch { throw .io(error) }
    do throws(TerminalError) {
      try raw.restore()
    } catch { throw .terminal(error) }
    return result
  }

  private mutating func runUnicodeSession(
    runner: inout ScreenRunner, input: borrowing RawMode, output: borrowing Output,
    signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> ScreenRunResult {
    if runner.capabilities.unicode == .ascii {
      return try runTrackedSession(runner: &runner, input: input, output: output, signals: signals)
    }
    let graphemes: GraphemeClustering
    do throws(IOError) { graphemes = try output.graphemeClustering() } catch { throw .io(error) }
    let result = try runTrackedSession(runner: &runner, input: input, output: output, signals: signals)
    do throws(IOError) { try graphemes.restore() } catch { throw .io(error) }
    return result
  }

  private mutating func runTrackedSession(
    runner: inout ScreenRunner, input: borrowing RawMode, output: borrowing Output,
    signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> ScreenRunResult {
    guard Self.configuration.mouseTracking else {
      return try runner.run(application: &self, input: input, output: output, signals: signals)
    }
    let mouse: MouseTracking
    do throws(IOError) { mouse = try output.mouseTracking() } catch { throw .io(error) }
    let result = try runner.run(application: &self, input: input, output: output, signals: signals)
    do throws(IOError) { try mouse.restore() } catch { throw .io(error) }
    return result
  }
}
