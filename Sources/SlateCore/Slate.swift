/// Interactive terminal session backed by raw mode + alternate screen (when initialized successfully).
@MainActor
public final class Slate {
  public enum InstallationError: Error {
    case notInteractiveTerminal
  }

  public private(set) var cols: Int
  public private(set) var rows: Int

  private let presenter = DoubleBufferedTerminalPresenter()

  /// Enter raw mode and bootstrap alternate-screen redraw state.
  ///
  /// If terminal setup fails after raw mode is entered, raw mode is cleared before the error propagates.
  /// Successful installs restore the saved tty in ``deinit`` (via ``MainActor/assumeIsolated`` — use ``Slate`` only on the main actor).
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
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)

    installationComplete = true
  }

  nonisolated deinit {
    // `deinit` is nonisolated; terminal globals are `@MainActor`. This assumes teardown runs on the main actor (true for `@MainActor main`).
    MainActor.assumeIsolated {
      ttyRestoreSaved()
    }
  }

  /// Reread ``TTY/windowSize()``, update ``cols`` / ``rows``, and resize encode buffers if needed.
  ///
  /// Call this when you receive ``TerminalWakeEvent/resize`` (or anytime dimensions may have changed outside ``TerminalWakePump``).
  public func refreshWindowSize() {
    let size = TTY.windowSize()
    cols = size.cols
    rows = size.rows
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
  }

  /// Encode `grid` using cached ``cols`` / ``rows`` and write one raw frame (no ``ioctl`` — dimensions come from ``init`` and ``refreshWindowSize()``).
  public func enscribe(grid: borrowing TerminalCellGrid) {
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
    presenter.presentFrame { buf in grid.encode(into: &buf) }
  }

  /// Runs stdin + periodic terminal-size polling (resize) + cross-isolation ``ExternalWake`` wakes until the stream ends or `onEvent` returns ``TerminalWakeRunOutcome/stop``.
  ///
  /// `prepare` runs once on the caller actor before ``run`` begins — use it to spawn work that calls ``ExternalWake/requestRender()`` (LLM stream, URL session, etc.; coalesced with swift-async-algorithms throttle to ``externalCoalesceMaxFramesPerSecond`` by default).
  /// On ``TerminalWakeEvent/resize``, call ``refreshWindowSize()`` before ``present`` so cached dimensions match the tty. Call ``present`` from `onEvent` when stdin, resize, or ``TerminalWakeEvent/external`` should refresh the screen (and once before ``start`` if you need an initial frame).
  /// Creates a ``TerminalWakePump`` for the loop; producers are stopped before this returns.
  public func start(
    prepare: (ExternalWake) -> Void = { _ in },
    externalCoalesceMaxFramesPerSecond: Int = 60,
    onEvent: @escaping @MainActor (TerminalWakeEvent) async -> TerminalWakeRunOutcome
  ) async {
    let pump = TerminalWakePump(externalCoalesceMaxFramesPerSecond: externalCoalesceMaxFramesPerSecond)
    prepare(pump.externalWake)
    await pump.run(onEvent: onEvent)
  }
}

@MainActor
private func writeRedrawBootstrapCSI() {
  var setup = CSI.altOn + CSI.curHide + CSI.clrHome
  setup.withUTF8 { unsafe ttyWriteRaw($0.span.bytes) }
}
