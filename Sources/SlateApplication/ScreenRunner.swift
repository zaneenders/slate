import SlateTerminal

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Owns all application-loop storage. No queued events, retained callbacks, or
/// tasks. Each poll handles at most 64 bytes, reusing 16 event slots until that
/// batch is consumed. Decoder work is bounded by supplied bytes and event slots;
/// paste framing can retain five delimiter bytes across input batches.
/// Cell and layout storage are allocated at startup; traversal is budgeted.
/// Paste storage is bounded by `configuration.maximumPasteBytes`; copy storage
/// grows with explicit copy requests. Both retain capacity for reuse.
/// Other storage is inline; no application borrows survive callbacks.
struct ScreenRunner: ~Copyable {
  private var screen: Screen
  private let overflow: ScreenApplicationConfiguration.ViewportOverflow
  private var input = TerminalInput()
  private var previousActualSize: TerminalSize?
  private var needsRedraw = true
  private var paste: PasteBuffer
  private var copyBuffer = CopyBuffer()
  private var ticks = TickSchedule()

  var capabilities: TerminalCapabilities { screen.capabilities }

  init(configuration: ScreenApplicationConfiguration) throws(ScreenError) {
    guard configuration.maximumPasteBytes > 0,
      configuration.maximumPasteBytes <= ScreenApplicationConfiguration.maximumPasteBytesLimit
    else { throw .invalidCapacity }
    screen = try Screen(
      maximumSize: configuration.maximumSize,
      capabilities: configuration.capabilities, layoutBudget: configuration.layoutBudget)
    paste = PasteBuffer(maximumBytes: configuration.maximumPasteBytes)
    overflow = configuration.viewportOverflow
  }

  borrowing func viewport(for actual: TerminalSize) throws(ScreenError) -> TerminalSize {
    switch overflow {
    case .clip:
      return TerminalSize(
        columns: min(actual.columns, screen.maximumSize.columns),
        rows: min(actual.rows, screen.maximumSize.rows))
    case .fail:
      guard actual.columns <= screen.maximumSize.columns, actual.rows <= screen.maximumSize.rows else {
        throw .viewportCapacityExceeded
      }
      return actual
    }
  }

  mutating func draw<Application: ScreenApplication & ~Copyable>(
    application: inout Application, actualSize: TerminalSize, to output: borrowing Output
  ) throws(ScreenError) {
    let size = try viewport(for: actualSize)
    if actualSize != previousActualSize {
      // A physical resize can disturb the display even if the clipped viewport
      // has not changed. Invalidate on the actual dimensions, not only the view.
      screen.invalidate()
      needsRedraw = true
    }
    guard needsRedraw else { return }
    try screen.draw(
      size: size, to: output,
      content: { application.render(in: size) },
      paint: { application.paint(in: &$0) })
    previousActualSize = actualSize
    needsRedraw = false
  }

  mutating func run<Application: ScreenApplication & ~Copyable>(
    application: inout Application, input: borrowing RawMode, output: borrowing Output,
    signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> ScreenRunResult {
    let clock = ContinuousClock()
    var inputBytes = InlineArray<64, UInt8>(repeating: 0)
    var retries = SystemCallRetryBudget()
    // This loop intentionally lasts for the application session. Work between
    // polls is bounded by one input batch, one application-bounded work step,
    // one tick, and one frame. Layout work scales with application node count.
    // Pending work uses nonblocking polls; timers can shorten the 50 ms
    // input/resize polling interval.
    while true {
      let number = signals.termination()
      if number != 0 { return .interrupted(number) }
      do throws(IOError) { try copyBuffer.flush(to: output) } catch { throw .io(error) }
      guard try expireInput(at: clock.now, application: &application) else { break }
      let actualSize: TerminalSize
      do throws(TerminalError) {
        actualSize = try output.terminalSize()
      } catch { throw .terminal(error) }
      do throws(ScreenError) {
        try draw(application: &application, actualSize: actualSize, to: output)
      } catch { throw .screen(error) }
      var readiness = pollfd(fd: input.rawDescriptor, events: Int16(POLLIN), revents: 0)
      let timeout = try pollTimeout(at: clock.now, application: application)
      let ready = unsafe poll(&readiness, 1, timeout)
      if ready < 0 {
        let error = errno
        if retries.retry(after: error) { continue }
        throw ScreenApplicationError.poll(errno: error)
      }
      // Deliver an expired Escape before decoding bytes arriving after it.
      guard try expireInput(at: clock.now, application: &application) else { break }
      if readiness.revents & Int16(POLLERR | POLLNVAL) != 0 { throw ScreenApplicationError.disconnected }
      if readiness.revents & Int16(POLLIN | POLLHUP) != 0 {
        let count: Int
        do throws(IOError) {
          count = try input.read(into: inputBytes.mutableSpan)
        } catch {
          // Return to the signal checks and poll instead of repeating a blocking
          // read. Poll/read interruptions share one budget until an iteration
          // completes, so successful polls cannot mask repeated read failures.
          if case .read(let number) = error, retries.retry(after: number) { continue }
          throw .io(error)
        }
        if count == 0 {
          if let event = self.input.finish() { _ = deliver(event, application: &application) }
          break
        }
        guard try receive(inputBytes.span.extracting(first: count), at: clock.now, application: &application) else { break }
      }
      retries = SystemCallRetryBudget()
      guard performPendingWork(application: &application) else { break }
      guard try tick(at: clock.now, application: &application) else { break }
    }
    do throws(IOError) { try copyBuffer.flush(to: output) } catch { throw .io(error) }
    return .quit
  }

  mutating func pollTimeout<Application: ScreenApplication & ~Copyable>(
    at now: ContinuousClock.Instant, application: borrowing Application
  ) throws(ScreenApplicationError) -> Int32 {
    try ticks.synchronize(interval: application.tickInterval, at: now)
    return application.hasPendingWork ? 0 : ticks.timeoutMilliseconds(at: now)
  }

  mutating func tick<Application: ScreenApplication & ~Copyable>(
    at now: ContinuousClock.Instant, application: inout Application
  ) throws(ScreenApplicationError) -> Bool {
    try ticks.synchronize(interval: application.tickInterval, at: now)
    guard let elapsed = ticks.next(at: now) else { return true }
    return apply(application.event(.tick(elapsed: elapsed), copyBuffer: &copyBuffer))
  }

  mutating func performPendingWork<Application: ScreenApplication & ~Copyable>(
    application: inout Application
  ) -> Bool {
    guard application.hasPendingWork else { return true }
    return apply(application.performPendingWork())
  }

  mutating func receive<Application: ScreenApplication & ~Copyable>(
    _ bytes: Span<UInt8>, at now: ContinuousClock.Instant, application: inout Application
  ) throws(ScreenApplicationError) -> Bool {
    precondition(bytes.count <= 64)
    guard !bytes.isEmpty else { return true }
    var offset = 0
    while true {
      let next: InputEvent?
      do throws(TerminalInputError) {
        next = try input.next(in: bytes, offset: &offset, at: now)
      } catch { throw .input(error) }
      guard let event = next else { break }
      guard deliver(event, application: &application) else { return false }
    }
    return true
  }

  mutating func expireInput<Application: ScreenApplication & ~Copyable>(
    at now: ContinuousClock.Instant, application: inout Application
  ) throws(ScreenApplicationError) -> Bool {
    let next: InputEvent?
    do throws(TerminalInputError) { next = try input.expire(at: now) } catch { throw .input(error) }
    guard let event = next else { return true }
    return deliver(event, application: &application)
  }

  private mutating func deliver<Application: ScreenApplication & ~Copyable>(
    _ event: InputEvent, application: inout Application
  ) -> Bool {
    let update: ScreenUpdate
    switch event {
    case .key(let key): update = application.event(.key(key), copyBuffer: &copyBuffer)
    case .modifiedKey(let key, let modifiers):
      update = application.event(.key(key, modifiers: modifiers), copyBuffer: &copyBuffer)
    case .mouse(let event): update = application.event(.mouse(event), copyBuffer: &copyBuffer)
    case .paste(.begin):
      paste.reset()
      return true
    case .paste(.byte(let byte)):
      paste.append(byte)
      return true
    case .paste(.cancelled):
      let error: PasteError = paste.isTooLarge ? .tooLarge : .incomplete
      paste.reset()
      update = application.event(.pasteRejected(error), copyBuffer: &copyBuffer)
    case .paste(.end):
      if paste.isTooLarge {
        update = application.event(.pasteRejected(.tooLarge), copyBuffer: &copyBuffer)
      } else if paste.isEmpty {
        update = application.event(.pasteEmpty, copyBuffer: &copyBuffer)
      } else {
        do throws(PasteError) {
          update = application.event(.paste(try paste.text()), copyBuffer: &copyBuffer)
        } catch {
          update = application.event(.pasteRejected(error), copyBuffer: &copyBuffer)
        }
      }
      paste.reset()
    default: return true
    }
    return apply(update)
  }

  private mutating func apply(_ update: ScreenUpdate) -> Bool {
    switch update {
    case .none: return true
    case .redraw:
      needsRedraw = true
      return true
    case .quit: return false
    }
  }
}
