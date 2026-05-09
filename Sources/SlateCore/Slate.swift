/// Interactive terminal session backed by raw mode + alternate screen (when initialized successfully).
///
/// ## Painting frames
///
/// The primary API is ``with(_:)`` — a scoped closure that receives the owned grid,
/// lets you paint into it, then automatically diffs (dirty-row tracking) and writes
/// the frame to the terminal:
///
/// ```swift
/// var slate = try Slate()
/// slate.with { grid in
///     grid.reset(filling: .defaultCell)
///     grid.blitText(column: 1, row: 1, string: "Hello", …)
/// }
/// ```
///
/// ## Event loop
///
/// Call ``subscribe(prepare:coalesceMaxFPS:onEvent:)`` to run the event loop.
/// It delivers ``TerminalWakeEvent`` values (stdin, resize, external wakes) to your
/// handler; paint inside the handler with ``with(_:)`` and return
/// ``TerminalWakeRunOutcome/stop`` to exit.
///
/// ```swift
/// await slate.subscribe(prepare: { wake in
///     // Spawn background work that calls wake.requestRender()
/// }) { slate, event in
///     switch event {
///     case .resize:       slate.refreshWindowSize()
///     case .stdinBytes:   /* decode input, mutate model */
///     case .external:     break
///     }
///     slate.with { grid in /* paint using current model state */ }
///     return .continue
/// }
/// ```
public struct Slate: ~Copyable {
  public enum InstallationError: Error {
    case notInteractiveTerminal
  }

  private var cols: Int
  private var rows: Int

  /// The reusable cell grid owned by this terminal session.
  ///
  /// **Prefer** ``with(_:)`` for painting — it scopes the mutation and guarantees
  /// the frame is written. Direct grid access is available for advanced use when
  /// you need to interleave grid reads/writes across multiple calls before
  /// calling ``enscribe()`` or ``enscribe(grid:)``.
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
    // Best-effort terminal restore for paths where ``start()`` was never called.
    // When ``start()`` is used it performs ordered async teardown (flush then
    // restore) before returning, so this call is a no-op because the restore
    // state has already been consumed.
    ttyRestoreSaved()
  }

  /// Reread ``TTY/windowSize()``, update ``cols`` / ``rows``, resize the grid,
  /// and resize encode buffers if needed.
  ///
  /// Call this when you receive ``TerminalWakeEvent/resize`` (or anytime dimensions
  /// may have changed outside ``TerminalWakePump``).
  public mutating func refreshWindowSize() {
    let size = TTY.windowSize()
    guard size.cols != cols || size.rows != rows else { return }
    cols = size.cols
    rows = size.rows
    _grid.resize(cols: cols, rows: rows, filling: .defaultCell)
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
  }

  /// Paint into the Slate-owned grid then encode + write one frame.
  ///
  /// The closure receives an `inout TerminalCellGrid` pre-sized to the current
  /// ``cols`` × ``rows``. Mutations mark rows dirty; after the closure returns,
  /// only dirty rows are encoded and written to the terminal via the
  /// double-buffered presenter.
  ///
  /// This is the **primary drawing API** — it replaces the pattern of accessing
  /// ``grid`` directly and then remembering to call ``enscribe()``:
  ///
  /// ```swift
  /// // Before (still works):
  /// slate.grid.reset(filling: .defaultCell)
  /// // … paint into slate.grid …
  /// slate.enscribe()
  ///
  /// // After (preferred):
  /// slate.with { grid in
  ///     grid.reset(filling: .defaultCell)
  ///     // … paint into grid …
  /// }
  /// ```
  public mutating func with(_ paint: (inout TerminalCellGrid) -> Void) {
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
    paint(&_grid)
    presenter.presentFrame { buf in _grid.encode(into: &buf) }
  }

  /// Paint into an externally-owned grid then encode + write one frame.
  ///
  /// Like ``with(_:)`` but receives the grid as an `inout` parameter so you can
  /// keep the grid in an external model object:
  ///
  /// ```swift
  /// slate.with(grid: &myModel.grid) { grid in
  ///     grid.reset(filling: .defaultCell)
  ///     // … paint into grid …
  /// }
  /// ```
  public mutating func with(grid: inout TerminalCellGrid, _ paint: (inout TerminalCellGrid) -> Void) {
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
    paint(&grid)
    presenter.presentFrame { buf in grid.encode(into: &buf) }
  }

  /// Encode the Slate-owned ``grid`` and write one raw frame.
  ///
  /// Only rows modified since the last encode are emitted (dirty-region tracking).
  /// The grid's dirty flags are cleared as each row is encoded.
  ///
  /// No ``ioctl`` — dimensions come from ``init`` and ``refreshWindowSize()``.
  ///
  /// **Prefer** ``with(_:)`` — it scopes grid mutation so you can't forget to encode.
  public mutating func enscribe() {
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
    presenter.presentFrame { buf in _grid.encode(into: &buf) }
  }

  /// Encode an externally-owned `grid` using cached ``cols`` / ``rows`` and write one
  /// raw frame. Prefer ``with(grid:_:)`` when using an external grid.
  ///
  /// Only rows modified since the last encode are emitted (dirty-region tracking).
  /// The grid's dirty flags are cleared as each row is encoded.
  public func enscribe(grid: inout TerminalCellGrid) {
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

  /// Subscribe to terminal events — the primary event-loop entry point.
  ///
  /// Delivers ``TerminalWakeEvent`` values (stdin bytes, resize, external wakes)
  /// to `onEvent` until the stream ends or the handler returns
  /// ``TerminalWakeRunOutcome/stop``. Automatic teardown: flushes the final frame,
  /// waits for the writer task, then restores the terminal.
  ///
  /// `prepare` runs once synchronously before the loop — use it to spawn
  /// background work that calls ``ExternalWake/requestRender()`` (LLM stream,
  /// URL session, etc.). External wakes are coalesced via throttle to
  /// `coalesceMaxFPS` (default 60; pass 0 for immediate delivery).
  ///
  /// ```swift
  /// await slate.subscribe(prepare: { wake in
  ///     Task { /* stream tokens, call wake.requestRender() */ }
  /// }) { slate, event in
  ///     switch event {
  ///     case .resize:     slate.refreshWindowSize()
  ///     case .stdinBytes: /* decode input */
  ///     case .external:   break
  ///     }
  ///     slate.with { grid in /* paint current model state */ }
  ///     return .continue
  /// }
  /// ```
  ///
  /// This is the same as ``start(prepare:externalCoalesceMaxFramesPerSecond:onEvent:)``
  /// with a more discoverable name. Both are interchangeable.
  @MainActor
  public mutating func subscribe(
    prepare: (ExternalWake) -> Void = { _ in },
    coalesceMaxFPS: Int = 60,
    onEvent: @MainActor (inout Self, TerminalWakeEvent) async -> TerminalWakeRunOutcome
  ) async {
    await start(
      prepare: prepare,
      externalCoalesceMaxFramesPerSecond: coalesceMaxFPS,
      onEvent: onEvent)
  }
}

private func writeRedrawBootstrapCSI() {
  // Enabling bracketed paste here (matched by ``ttyRestoreSaved`` on teardown) lets the terminal
  // wrap pasted text with `\e[200~` / `\e[201~` so ``TerminalKeyDecoder`` can keep pasted
  // newlines distinct from a typed Enter.
  var setup = CSI.altOn + CSI.curHide + CSI.bracketedPasteOn + CSI.clrHome
  setup.withUTF8 { unsafe ttyWriteRaw($0.span.bytes) }
}
