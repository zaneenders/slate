/// Interactive terminal session backed by raw mode + alternate screen (when initialized successfully).
public struct Slate: ~Copyable {
  public enum InstallationError: Error {
    case notInteractiveTerminal
  }

  public private(set) var cols: Int
  public private(set) var rows: Int

  /// The reusable cell grid owned by this terminal session.
  /// Paint into it between ``enscribe()`` calls; dirty-region tracking
  /// ensures only modified rows are emitted to the tty.
  ///
  /// ```swift
  /// slate.grid.reset(filling: .defaultCell)
  /// // ... paint into slate.grid ...
  /// slate.enscribe()
  /// ```
  public var grid: TerminalCellGrid {
    _read { yield _grid }
    _modify { yield &_grid }
  }

  private var _grid: TerminalCellGrid
  private let presenter = DoubleBufferedTerminalPresenter()

  public init() throws {
    guard ttyEnterRawOrExit() else {
      throw InstallationError.notInteractiveTerminal
    }
    var installationComplete = false
    defer {
      if !installationComplete {
        ttyRestoreSaved()
      }
    }

    writeRedrawBootstrapCSI()
    let size = TTY.windowSize()
    cols = size.cols
    rows = size.rows
    _grid = TerminalCellGrid(cols: cols, rows: rows, filling: .defaultCell)
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)

    installationComplete = true
  }

  deinit {
    ttyRestoreSaved()
  }

  public mutating func refreshWindowSize() {
    let size = TTY.windowSize()
    guard size.cols != cols || size.rows != rows else { return }
    cols = size.cols
    rows = size.rows
    _grid.resize(cols: cols, rows: rows, filling: .defaultCell)
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
  }

  public mutating func enscribe() {
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
    presenter.presentFrame { buf in _grid.encode(into: &buf) }
  }

  public func enscribe(grid: inout TerminalCellGrid) {
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
    presenter.presentFrame { buf in grid.encode(into: &buf) }
  }

  @MainActor
  public mutating func start(
    prepare: (ExternalWake) -> Void = { _ in },
    externalCoalesceMaxFramesPerSecond: Int = 60,
    onEvent: @MainActor (inout Self, TerminalWakeEvent) async -> TerminalWakeRunOutcome
  ) async {
    let pump = TerminalWakePump(externalCoalesceMaxFramesPerSecond: externalCoalesceMaxFramesPerSecond)
    defer { pump.stop() }
    prepare(pump.externalWake)
    for await event in pump.events {
      if await onEvent(&self, event) == .stop { break }
    }
    await presenter.flushAndStopWriter()
    ttyRestoreSaved()
  }
}

private func writeRedrawBootstrapCSI() {
  var setup = CSI.altOn + CSI.curHide + CSI.bracketedPasteOn + CSI.clrHome
  setup.withUTF8 { unsafe ttyWriteRaw($0.span.bytes) }
}
