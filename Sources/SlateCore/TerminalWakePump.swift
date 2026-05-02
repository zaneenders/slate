import AsyncAlgorithms
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One wake from stdin, terminal resize, or an outside producer (LLM tokens, network, etc.).
/// Redraw by calling ``Slate/present`` (or your own output) inside the handler.
public enum TerminalWakeEvent: Sendable {
  /// Terminal dimensions may have changed (detected via periodic ``TIOCGWINSZ`` poll). Read size via ``TTY/windowSize()`` or ``Slate/present``.
  case resize
  /// stdin read **in one wakeup** — chunks are often larger when pasting or when the tty has buffered keystrokes together. Empty means EOF (stdin closed).
  case stdinBytes(ContiguousArray<UInt8>)
  /// Another source asked for a frame (``ExternalWake/requestRender()``). Read shared model / buffer and ``present``.
  case external
}

/// Return value from ``TerminalWakePump/run(onEvent:)``.
public enum TerminalWakeRunOutcome: Sendable {
  case `continue`
  case stop
}

/// Wakes the main loop from any isolation — e.g. each LLM token, a socket read, or a background ``Task``.
///
/// ``TerminalWakePump`` vends one value per instance; hold it and call ``requestRender()`` when output should refresh.
/// Calls are coalesced with [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) ``AsyncSequence`` throttle (``_throttle(for:latest:)``, `latest: true`) at ``TerminalWakePump/externalCoalesceMaxFramesPerSecond`` (default ``60``); pass ``0`` if every call must enqueue ``TerminalWakeEvent/external`` immediately.
public struct ExternalWake: Sendable {
  private let emit: @Sendable () -> Void

  init(emit: @escaping @Sendable () -> Void) {
    self.emit = emit
  }

  /// Enqueues ``TerminalWakeEvent/external`` for the pump's ``run(onEvent:)`` loop.
  public func requestRender() {
    emit()
  }
}

private enum ExternalWakeSignal: Sendable {
  case tick
}

/// Never calls `yield`/`finish` while holding the mutex (see deadlocks with `@MainActor` consumers).
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

/// Polls ``TTYPoll/windowSize()`` and emits ``TerminalWakeEvent/resize`` when the terminal dimensions change (no GCD / ``Dispatch``).
private func startResizePollTask(bus: WakeBus, interval: Duration) -> Task<Void, Never> {
  Task.detached { [bus] in
    var last: (cols: Int, rows: Int)?
    while !Task.isCancelled {
      try? await Task.sleep(for: interval)
      let s = TTYPoll.windowSize()
      if let l = last, l.cols != s.cols || l.rows != s.rows {
        bus.emit(.resize)
      }
      last = (s.cols, s.rows)
    }
  }
}

/// Starts stdin wakes, periodic terminal-size polling (resize), and optional external-wake throttling; ``stop()`` tears producers down and finishes ``events``.
///
/// ``ExternalWake`` forwards through [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) throttle (``_throttle(for:latest:)``) when ``externalCoalesceMaxFramesPerSecond`` is positive (default ``60``).
///
/// Resize is detected by polling ``TTYPoll/windowSize()`` (``TIOCGWINSZ``), not ``Dispatch`` or signal handlers.
@MainActor
public final class TerminalWakePump {
  /// Low-level stream. Prefer ``run(onEvent:)`` for a structured loop that ends with ``stop()``.
  public let events: AsyncStream<TerminalWakeEvent>
  /// Pass to code that runs outside the pump (streaming APIs, ``Task.detached``, callbacks). See ``ExternalWake``.
  public let externalWake: ExternalWake
  private let bus: WakeBus
  private var externalSignalContinuation: AsyncStream<ExternalWakeSignal>.Continuation?
  private var externalThrottleConsumer: Task<Void, Never>?
  private let stdinWake: Task<Void, Never>
  private var resizePollTask: Task<Void, Never>?

  private func installResizePoll(bus: WakeBus) {
    resizePollTask = startResizePollTask(bus: bus, interval: .milliseconds(100))
  }

  private func teardownResizePoll() {
    resizePollTask?.cancel()
    resizePollTask = nil
  }

  /// - Parameter externalCoalesceMaxFramesPerSecond: ``ExternalWake/requestRender()`` feeds an ``AsyncStream`` through throttle (see [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)) with `latest: true`, so bursty requests become at most this many ``TerminalWakeEvent/external`` per second. Use ``0`` for no cap (one event per call).
  public init(externalCoalesceMaxFramesPerSecond: Int = 60) {
    let coalesceFps = max(0, externalCoalesceMaxFramesPerSecond)
    let (stream, continuation) = AsyncStream.makeStream(
      of: TerminalWakeEvent.self,
      bufferingPolicy: .unbounded)
    let bus = WakeBus(continuation)
    self.events = stream
    self.bus = bus

    if coalesceFps == 0 {
      externalSignalContinuation = nil
      externalThrottleConsumer = nil
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

    stdinWake = startStdinWakeTask(bus: bus)
    installResizePoll(bus: bus)
  }

  public func stop() {
    externalSignalContinuation?.finish()
    externalSignalContinuation = nil
    externalThrottleConsumer?.cancel()
    externalThrottleConsumer = nil
    stdinWake.cancel()
    teardownResizePoll()
    bus.finish()
  }

  /// Runs until the stream ends or `onEvent` returns ``TerminalWakeRunOutcome/stop``.
  /// Always invokes ``stop()`` before returning (safe if the stream already finished).
  public func run(
    onEvent: @escaping @MainActor (TerminalWakeEvent) async -> TerminalWakeRunOutcome
  ) async {
    defer { stop() }
    for await event in events {
      if await onEvent(event) == .stop {
        return
      }
    }
  }
}
