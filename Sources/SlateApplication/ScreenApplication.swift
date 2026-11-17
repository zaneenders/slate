@_exported public import SlateKittyGraphics
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
  public let layoutBudget: LayoutBudget
  public let viewportOverflow: ViewportOverflow
  /// Own scoped SGR mouse tracking for the active session.
  public let mouseTracking: Bool
  /// Request disambiguated keys, including Super/Command, on terminals that
  /// support the Kitty keyboard protocol. Native terminal shortcuts still win.
  public let enhancedKeyboard: Bool
  /// Send an explicit Kitty graphics support query once the input session is
  /// ready. Match this nonzero ID in .kittyGraphicsReply, or fall back when
  /// .primaryDeviceAttributes arrives first. Nil (default) performs no query.
  public let kittyGraphicsQueryID: UInt32?
  public let capabilities: TerminalCapabilities
  /// Maximum bracketed-paste payload retained in memory. Oversized pastes are
  /// consumed through their terminator and reported as `.pasteRejected(.tooLarge)`.
  public let maximumPasteBytes: Int

  public init(
    maximumSize: TerminalSize = TerminalSize(columns: 240, rows: 80),
    viewportOverflow: ViewportOverflow = .clip,
    mouseTracking: Bool = false,
    enhancedKeyboard: Bool = false,
    kittyGraphicsQueryID: UInt32? = nil,
    capabilities: TerminalCapabilities = .init(),
    maximumPasteBytes: Int = ScreenApplicationConfiguration.defaultMaximumPasteBytes,
    layoutBudget: LayoutBudget = .init()
  ) {
    self.maximumSize = maximumSize
    self.layoutBudget = layoutBudget
    self.viewportOverflow = viewportOverflow
    self.mouseTracking = mouseTracking
    self.enhancedKeyboard = enhancedKeyboard
    self.kittyGraphicsQueryID = kittyGraphicsQueryID
    self.capabilities = capabilities
    self.maximumPasteBytes = maximumPasteBytes
  }
}

public enum ScreenApplicationError: Error, Equatable, Sendable {
  case screen(ScreenError)
  case terminal(TerminalError)
  case io(IOError)
  case input(TerminalInputError)
  case poll(errno: Int32)
  case disconnected
  case signalSetup(errno: Int32)
  case interrupted(signal: Int32)
  case cancelled
  case invalidTickInterval
  case graphics(KittyGraphicsError)
}

/// Main-actor application callbacks. ScreenSession owns I/O, storage, and task lifetime.
///
/// The first frame and physical resizes render automatically. Invalid input
/// sequences are ignored; decoded input, including Ctrl-C, belongs to `event`.
/// Expired APC responses are discarded with bounded recovery; recovery failure
/// throws `.input(.responseRecoveryExceeded)` and unwinds the terminal scopes.
/// All decoded keys, including Ctrl-Z, belong to `event` and can be rebound.
/// Managed sessions ignore SIGTSTP while keeping Ctrl-Z available as input.
/// Event callbacks may not retain frame/paste borrows or start another terminal
/// reader.
@MainActor
public protocol ScreenApplication: ~Copyable {
  associatedtype Content: Block
  mutating func start(in session: ScreenSession)
  mutating func stop() async
  /// Synchronizes widget state after a wake, before input and drawing. Clipboard storage stays within this callback.
  mutating func update(copyBuffer: inout CopyBuffer) -> ScreenUpdate
  static var configuration: ScreenApplicationConfiguration { get }
  /// Interval between timed events. Ticks are disabled unless explicitly requested.
  /// Intervals must be positive or run throws `.invalidTickInterval`.
  /// Changes restart the interval. Late ticks are skipped, never queued.
  /// Polling rounds up to whole milliseconds; callbacks and I/O can delay delivery.
  var tickInterval: Duration? { get }
  /// Whether another bounded work step can run without waiting for input.
  /// Default is false. The runner presents the first frame before doing work.
  var hasPendingWork: Bool { get }
  /// Requests a graphics batch without rebuilding cells; clear this request during presentGraphics.
  var hasPendingGraphics: Bool { get }
  /// Performs one synchronous, application-bounded batch after checking input.
  /// Return `.redraw` when progress should be presented or `.quit` to stop.
  /// Do not retain frame borrows or start another terminal reader here.
  mutating func performPendingWork() -> ScreenUpdate
  /// Receives ticks, keys, mouse input, pastes, paste failures, and terminal replies.
  /// Default returns `.none`. Copy requests are prepared synchronously and written
  /// after this input batch.
  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate
  @BlockBuilder borrowing func render(in size: TerminalSize) -> Content
  /// Draws after block layout, before presentation. The frame cannot escape.
  /// Use this for application-owned editors, charts, or other custom views.
  borrowing func paint(in frame: inout Frame)
  /// Observes each successfully presented cell frame, including zero-byte diffs,
  /// before presentGraphics. Skipped draws and failed frames do not call this.
  /// Default does nothing. Counts exclude image commands and terminal setup.
  /// Observation is synchronous; retained history/logging belongs to the caller.
  mutating func didPresentFrame(_ statistics: FrameStatistics)
  /// Presents terminal images after a successful cell frame, including resizes.
  /// Shares the session's output writer; do not start another input reader.
  /// Upload reusable images once and recreate their placements here as needed.
  mutating func presentGraphics(in size: TerminalSize, to output: borrowing Output) throws(KittyGraphicsError)
  /// Releases terminal images before leaving the alternate screen. Called on
  /// normal exit and during error/signal unwinding, including partial uploads.
  /// Must tolerate absent images and repeated calls after a cleanup failure.
  mutating func clearGraphics(to output: borrowing Output) throws(KittyGraphicsError)
}

extension ScreenApplication where Self: ~Copyable {
  public mutating func start(in session: ScreenSession) {}
  public mutating func stop() async {}
  public mutating func update(copyBuffer: inout CopyBuffer) -> ScreenUpdate { .none }
  public static var configuration: ScreenApplicationConfiguration { .init() }
  public var tickInterval: Duration? { nil }
  public var hasPendingWork: Bool { false }
  public var hasPendingGraphics: Bool { false }
  public mutating func performPendingWork() -> ScreenUpdate { .none }
  public mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate { .none }
  public borrowing func paint(in frame: inout Frame) {}
  public mutating func didPresentFrame(_ statistics: FrameStatistics) {}
  public mutating func presentGraphics(in size: TerminalSize, to output: borrowing Output) throws(KittyGraphicsError) {}
  public mutating func clearGraphics(to output: borrowing Output) throws(KittyGraphicsError) {}
}
