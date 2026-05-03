/// Interactive terminal session backed by raw mode + alternate screen (when initialized successfully).
public struct Slate: ~Copyable {
  public enum InstallationError: Error {
    case notInteractiveTerminal
  }

  public private(set) var cols: Int
  public private(set) var rows: Int

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
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)

    installationComplete = true
  }

  deinit {
    // Best-effort terminal restore for paths where ``start()`` was never called.
    // When ``start()`` is used it performs ordered async teardown (flush then
    // restore) before returning, so this call is a no-op because the restore
    // state has already been consumed.
    ttyRestoreSaved()
  }

  /// Reread ``TTY/windowSize()``, update ``cols`` / ``rows``, and resize encode buffers if needed.
  ///
  /// Call this when you receive ``TerminalWakeEvent/resize`` (or anytime dimensions may have changed outside ``TerminalWakePump``).
  public mutating func refreshWindowSize() {
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
  /// `prepare` runs once on the caller actor before the event loop begins — use it to spawn work that calls ``ExternalWake/requestRender()`` (LLM stream, URL session, etc.; coalesced with swift-async-algorithms throttle to ``externalCoalesceMaxFramesPerSecond`` by default).
  ///
  /// `onEvent` receives the active ``Slate`` as an `inout` parameter rather than capturing it from the enclosing scope — escaping closures cannot capture noncopyable values, so the inout passes a fresh borrow per call. Inside the handler, call ``refreshWindowSize()`` on ``TerminalWakeEvent/resize`` before re-encoding, and call ``enscribe(grid:)`` whenever stdin, resize, or ``TerminalWakeEvent/external`` should refresh the screen.
  ///
  /// Creates a ``TerminalWakePump`` for the loop; producers are stopped before this returns.
  ///
  /// `@MainActor` here is the **only** isolation annotation in the public API — see the type-level
  /// docs for why. ``TerminalWakePump`` keeps unsynchronized lifecycle vars on its single owner,
  /// and the ``onEvent`` closure typically captures app state (``DemoTranscript`` etc.) that the
  /// caller's `@main`-isolated code mutates from spawned tasks; pinning ``start`` to the main
  /// actor matches the realistic usage pattern without forcing every other ``Slate`` method to
  /// be `@MainActor`.
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
    // Ordered async teardown: flush the final frame, wait for the writer task
    // to drain, then restore the terminal. `ttyRestoreSaved()` is idempotent,
    // so the matching `deinit` call becomes a no-op.
    await presenter.flushAndStopWriter()
    ttyRestoreSaved()
  }
}

private func writeRedrawBootstrapCSI() {
  var setup = CSI.altOn + CSI.curHide + CSI.clrHome
  setup.withUTF8 { unsafe ttyWriteRaw($0.span.bytes) }
}
