import AsyncAlgorithms
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Wake event types

/// One wake from stdin, terminal resize, or an outside producer (LLM tokens, network, etc.).
/// Redraw by calling ``Slate/with(_:)`` inside the handler.
public enum TerminalWakeEvent: Sendable {
  /// Terminal dimensions may have changed (detected via periodic ``TIOCGWINSZ`` poll). Read size via ``TTY/windowSize()`` or refresh via ``Slate/refreshWindowSize()`` before ``Slate/with(_:)``.
  case resize
  /// stdin read **in one wakeup** — chunks are often larger when pasting or when the tty has buffered keystrokes together. Empty means EOF (stdin closed).
  case stdinBytes(ContiguousArray<UInt8>)
  /// Another source asked for a frame (``ExternalWake/requestRender()``). Read shared model / buffer and redraw with ``Slate/with(_:)``.
  case external
}

/// Return value from the `onEvent` closure passed to ``Slate/subscribe(prepare:coalesceMaxFPS:onEvent:)``.
public enum TerminalWakeRunOutcome: Sendable {
  case `continue`
  case stop
}

/// Wakes the main loop from any isolation — e.g. each LLM token, a socket read, or a background ``Task``.
///
/// ``Slate/subscribe(prepare:coalesceMaxFPS:onEvent:)`` passes one value to `prepare`; hold it and call ``requestRender()`` when output should refresh.
/// Calls are coalesced with [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) ``AsyncSequence`` throttle (``_throttle(for:latest:)``, `latest: true`) at `coalesceMaxFPS` (default `60`); pass `0` if every call must enqueue ``TerminalWakeEvent/external`` immediately.
public struct ExternalWake: Sendable {
  private let emit: @Sendable () -> Void

  init(emit: @escaping @Sendable () -> Void) {
    self.emit = emit
  }

  /// Enqueues ``TerminalWakeEvent/external`` for the event loop.
  public func requestRender() {
    emit()
  }
}

// MARK: - Private wake infrastructure

private enum ExternalWakeSignal: Sendable {
  case tick
}

private final class WakeBus: Sendable {
  private struct Box: Sendable {
    var continuation: AsyncStream<TerminalWakeEvent>.Continuation?
  }

  private let state: Mutex<Box>

  init(_ continuation: AsyncStream<TerminalWakeEvent>.Continuation) {
    state = Mutex(Box(continuation: continuation))
  }

  func emit(_ reason: TerminalWakeEvent) {
    let continuation = state.withLock { box in box.continuation }
    continuation?.yield(reason)
  }

  func finish() {
    let continuation = state.withLock { box in
      let c = box.continuation
      box.continuation = nil
      return c
    }
    continuation?.finish()
  }
}

private func startStdinWakeTask(bus: WakeBus) -> Task<Void, Never> {
  let chunkCapacity = 16_384
  return Task.detached { [bus] in
    var scratch = [UInt8](repeating: 0, count: chunkCapacity)
    while !Task.isCancelled {
      var aggregate = ContiguousArray<UInt8>()
      aggregate.reserveCapacity(chunkCapacity)

      gather: while true {
        let grabbed: Int =
          unsafe scratch.withUnsafeMutableBytes { raw in
            unsafe read(STDIN_FILENO, raw.baseAddress!, raw.count)
          }
        if grabbed < 0 {
          if errno == EINTR {
            continue gather
          }
          bus.emit(.stdinBytes(.init()))
          bus.finish()
          return
        }
        if grabbed == 0 {
          break gather
        }
        aggregate.append(contentsOf: scratch[..<grabbed])
        if grabbed < scratch.count {
          break gather
        }
      }

      if aggregate.isEmpty {
        bus.emit(.stdinBytes(.init()))
        bus.finish()
        return
      }

      bus.emit(.stdinBytes(aggregate))
    }
  }
}

/// Polls ``TTY/windowSize()`` and emits ``TerminalWakeEvent/resize`` when the terminal dimensions change (no GCD / ``Dispatch``).
private func startResizePollTask(bus: WakeBus, interval: Duration) -> Task<Void, Never> {
  Task.detached { [bus] in
    var last: (cols: Int, rows: Int)? = nil
    while !Task.isCancelled {
      try? await Task.sleep(for: interval)
      let s = TTY.windowSize()
      if let l = last, l.cols != s.cols || l.rows != s.rows {
        bus.emit(.resize)
      }
      last = (s.cols, s.rows)
    }
  }
}

// MARK: - Slate

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
  /// may have changed outside the event loop).
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
  /// This is the **only drawing API** for the built-in grid:
  ///
  /// ```swift
  /// slate.with { grid in
  ///     grid.reset(filling: .defaultCell)
  ///     // … paint into grid …
  /// }
  /// ```
  public mutating func with(_ paint: (inout TerminalCellGrid) -> Void) {
    paint(&_grid)
    enscribe()
  }

  internal mutating func enscribe() {
    presenter.ensureEncodedByteCapacity(for: cols, rows: rows)
    presenter.presentFrame { buf in _grid.encode(into: &buf) }
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
  /// `@MainActor` here is the **only** isolation annotation in the public API — see the type-level
  /// docs for why. The event-loop infrastructure keeps unsynchronized lifecycle vars on its single owner,
  /// and the `onEvent` closure typically captures app state (``DemoTranscript`` etc.) that the
  /// caller's `@main`-isolated code mutates from spawned tasks; pinning `subscribe` to the main
  /// actor matches the realistic usage pattern without forcing every other ``Slate`` method to
  /// be `@MainActor`.
  @MainActor
  public mutating func subscribe(
    prepare: (ExternalWake) -> Void = { _ in },
    coalesceMaxFPS: Int = 60,
    onEvent: @MainActor (inout Self, TerminalWakeEvent) async -> TerminalWakeRunOutcome
  ) async {
    // ── Build the wake pipeline ──────────────────────────────────────────────
    let coalesceFps = max(0, coalesceMaxFPS)
    let (stream, continuation) = AsyncStream.makeStream(
      of: TerminalWakeEvent.self,
      bufferingPolicy: .unbounded)
    let bus = WakeBus(continuation)

    let externalWake: ExternalWake
    var externalSignalContinuation: AsyncStream<ExternalWakeSignal>.Continuation?
    var externalThrottleConsumer: Task<Void, Never>?

    if coalesceFps == 0 {
      externalWake = ExternalWake { [bus] in bus.emit(.external) }
    } else {
      let (signalStream, signalContinuation) = AsyncStream.makeStream(
        of: ExternalWakeSignal.self,
        bufferingPolicy: .unbounded)
      externalSignalContinuation = signalContinuation
      let throttleInterval = Duration.seconds(1) / max(1, coalesceFps)
      let throttled = signalStream._throttle(for: throttleInterval, latest: true)
      externalThrottleConsumer = Task.detached { [bus] in
        for await _ in throttled {
          bus.emit(.external)
        }
      }
      externalWake = ExternalWake { signalContinuation.yield(.tick) }
    }

    let stdinWake = startStdinWakeTask(bus: bus)
    let resizePollTask = startResizePollTask(bus: bus, interval: .milliseconds(100))

    defer {
      externalSignalContinuation?.finish()
      externalThrottleConsumer?.cancel()
      stdinWake.cancel()
      resizePollTask.cancel()
      bus.finish()
    }

    // ── Event loop ──────────────────────────────────────────────────────────
    prepare(externalWake)
    for await event in stream {
      if await onEvent(&self, event) == .stop { break }
    }

    // ── Ordered teardown ────────────────────────────────────────────────────
    await presenter.flushAndStopWriter()
    ttyRestoreSaved()
  }
}

// MARK: - Bootstrap helpers

private func writeRedrawBootstrapCSI() {
  // Enabling bracketed paste here (matched by ``ttyRestoreSaved`` on teardown) lets the terminal
  // wrap pasted text with `\e[200~` / `\e[201~` so ``TerminalKeyDecoder`` can keep pasted
  // newlines distinct from a typed Enter.
  var setup = CSI.altOn + CSI.curHide + CSI.bracketedPasteOn + CSI.clrHome
  setup.withUTF8 { unsafe ttyWriteRaw($0.span.bytes) }
}
