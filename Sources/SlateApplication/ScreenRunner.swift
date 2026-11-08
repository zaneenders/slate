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
/// Screen storage is allocated at startup. Paste and copy storage grows with
/// incoming pastes and explicit copy requests, retaining capacity for reuse.
/// Other storage is inline; no application borrows survive callbacks or a
/// suspend/resume cycle.
struct ScreenRunner: ~Copyable {
  private var screen: Screen
  private let overflow: ScreenApplicationConfiguration.ViewportOverflow
  private var input = TerminalInput()
  private var previousActualSize: TerminalSize?
  private var needsRedraw = true
  private var paste = PasteBuffer()
  private var copyBuffer = CopyBuffer()
  private var handlesSuspension = false
  private var requestedSuspend = false

  mutating func resume() {
    screen.invalidate()
    previousActualSize = nil
    needsRedraw = true
    requestedSuspend = false
    // Preserve incomplete paste framing across suspension: its tail is data.
    input.resume(at: ContinuousClock().now)
  }

  init(configuration: ScreenApplicationConfiguration) throws(ScreenError) {
    screen = try Screen(maximumSize: configuration.maximumSize, nodeCapacity: configuration.nodeCapacity)
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
    handlesSuspension = signals.enabled
    let clock = ContinuousClock()
    var inputBytes = InlineArray<64, UInt8>(repeating: 0)
    var retries = SystemCallRetryBudget()
    // This loop intentionally lasts for the application session. Work between
    // polls is bounded by one input batch, one application-bounded work step,
    // and one capacity-limited frame. Pending work uses nonblocking polls;
    // idle applications retain the 50 ms input/resize deadline.
    while true {
      let number = signals.termination()
      if number != 0 { return .interrupted(number) }
      if signals.shouldSuspend() { return .suspend }
      do throws(IOError) { try copyBuffer.flush(to: output) } catch { throw .io(error) }
      guard expireEscape(at: clock.now, application: &application) else { break }
      let actualSize: TerminalSize
      do throws(TerminalError) {
        actualSize = try output.terminalSize()
      } catch { throw .terminal(error) }
      do throws(ScreenError) {
        try draw(application: &application, actualSize: actualSize, to: output)
      } catch { throw .screen(error) }
      var readiness = pollfd(fd: input.rawDescriptor, events: Int16(POLLIN), revents: 0)
      let ready = unsafe poll(&readiness, 1, application.hasPendingWork ? 0 : 50)
      if ready < 0 {
        let error = errno
        if retries.retry(after: error) { continue }
        throw ScreenApplicationError.poll(errno: error)
      }
      // Deliver an expired Escape before decoding bytes arriving after it.
      guard expireEscape(at: clock.now, application: &application) else { break }
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
          if let event = self.input.flush() { _ = deliver(event, application: &application) }
          break
        }
        guard receive(inputBytes.span.extracting(first: count), at: clock.now, application: &application) else { break }
      }
      retries = SystemCallRetryBudget()
      guard performPendingWork(application: &application) else { break }
    }
    do throws(IOError) { try copyBuffer.flush(to: output) } catch { throw .io(error) }
    return requestedSuspend ? .suspend : .quit
  }

  mutating func performPendingWork<Application: ScreenApplication & ~Copyable>(
    application: inout Application
  ) -> Bool {
    guard application.hasPendingWork else { return true }
    switch application.performPendingWork() {
    case .none: return true
    case .redraw:
      needsRedraw = true
      return true
    case .quit:
      requestedSuspend = false
      return false
    }
  }

  mutating func receive<Application: ScreenApplication & ~Copyable>(
    _ bytes: Span<UInt8>, at now: ContinuousClock.Instant, application: inout Application
  ) -> Bool {
    precondition(bytes.count <= 64)
    guard !bytes.isEmpty else { return true }
    var offset = 0
    while let event = input.next(in: bytes, offset: &offset, at: now) {
      guard deliver(event, application: &application) else { return false }
    }
    return !requestedSuspend
  }

  mutating func expireEscape<Application: ScreenApplication & ~Copyable>(
    at now: ContinuousClock.Instant, application: inout Application
  ) -> Bool {
    guard let event = input.expire(at: now) else { return true }
    return deliver(event, application: &application)
  }

  private mutating func deliver<Application: ScreenApplication & ~Copyable>(
    _ event: InputEvent, application: inout Application
  ) -> Bool {
    let update: ScreenUpdate
    switch event {
    case .key(.control(.z)) where handlesSuspension:
      requestedSuspend = true
      return true
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
      paste.reset()
      update = application.event(.pasteRejected(.incomplete), copyBuffer: &copyBuffer)
    case .paste(.end):
      do throws(PasteError) {
        update = application.event(.paste(try paste.text()), copyBuffer: &copyBuffer)
      } catch {
        update = application.event(.pasteRejected(error), copyBuffer: &copyBuffer)
      }
      paste.reset()
    default: return true
    }
    switch update {
    case .none: return true
    case .redraw:
      needsRedraw = true
      return true
    case .quit:
      requestedSuspend = false
      return false
    }
  }
}
