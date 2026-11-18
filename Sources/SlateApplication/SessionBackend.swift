import BasicContainers
import Foundation
import SlateTerminal
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum BackendCommand: Sendable {
  case start
  case poll(Int32, UInt64, Bool)
  case flush, cleanup, stop
}

struct BackendEvent: Sendable {
  var size: TerminalSize
  var bytes: InlineArray<64, UInt8>
  var count: Int
  var endOfInput: Bool
  var woken: Bool
}

/// One worker, one outstanding request, two startup output buffers, and a coalescing wake pipe.
final class SessionBackend: Sendable {
  private static let restorationTimeout = Duration.milliseconds(200)

  private struct State {
    var command: BackendCommand?
    var continuation: CheckedContinuation<Result<BackendEvent, ScreenApplicationError>, Never>?
    var generation: UInt64 = 0
    var finished = false
    var interruptRequested = false
    var result: Result<BackendEvent, ScreenApplicationError>?
  }
  private let state = Mutex(State())
  private let wakeRead: Int32
  private let wakeWrite: Int32
  private let inputDescriptor: Int32
  private let outputDescriptor: Int32
  private let configuration: ScreenApplicationConfiguration
  private let signalHandling: ScreenSignalHandling
  let outputBuffer: OutputBuffer

  init(
    inputDescriptor: Int32, outputDescriptor: Int32,
    configuration: ScreenApplicationConfiguration, signalHandling: ScreenSignalHandling,
    outputBuffer: OutputBuffer
  ) throws(ScreenApplicationError) {
    var descriptors: InlineArray<2, Int32> = [-1, -1]
    var storage = descriptors.mutableSpan
    let result = storage.withUnsafeMutableBufferPointer { unsafe pipe($0.baseAddress!) }
    guard result == 0 else { throw .poll(errno: errno) }
    for index in 0..<2 {
      // Keep closed standard descriptors closed, as Input and Output do for their duplicates.
      if descriptors[index] < 3 {
        let original = descriptors[index]
        let duplicate = fcntl(original, F_DUPFD_CLOEXEC, 3)
        if duplicate < 0 {
          let error = errno
          _ = close(descriptors[0])
          _ = close(descriptors[1])
          throw .poll(errno: error)
        }
        _ = close(original)
        descriptors[index] = duplicate
      }
      let descriptor = descriptors[index]
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
        fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
      else {
        let error = errno
        _ = close(descriptors[0])
        _ = close(descriptors[1])
        throw .poll(errno: error)
      }
    }
    wakeRead = descriptors[0]
    wakeWrite = descriptors[1]
    self.inputDescriptor = inputDescriptor
    self.outputDescriptor = outputDescriptor
    self.configuration = configuration
    self.signalHandling = signalHandling
    self.outputBuffer = outputBuffer
  }

  deinit {
    _ = close(wakeRead)
    _ = close(wakeWrite)
  }

  func generation() -> UInt64 { state.withLock { $0.generation } }

  func wake() {
    state.withLock { $0.generation &+= 1 }
    notify()
  }

  private func notify() {
    var byte: UInt8 = 1
    // A full pipe already represents a wake. EINTR is bounded and retried.
    var retries = SystemCallRetryBudget()
    while unsafe write(wakeWrite, &byte, 1) < 0 {
      if retries.retry(after: errno) { continue }
      break
    }
  }

  func interruptIO() {
    state.withLock { $0.interruptRequested = true }
    wake()
  }

  private func checkInterruption(_ signals: borrowing SignalSession) throws(ScreenApplicationError) {
    let number = signals.termination()
    if number != 0 { throw .interrupted(signal: number) }
    if state.withLock({ $0.interruptRequested }) { throw .cancelled }
  }

  func request(_ command: BackendCommand) async -> Result<BackendEvent, ScreenApplicationError> {
    await withCheckedContinuation { continuation in
      let completed = state.withLock { state -> Result<BackendEvent, ScreenApplicationError>? in
        if state.finished { return state.result }
        precondition(state.continuation == nil && state.command == nil)
        state.command = command
        state.continuation = continuation
        return nil
      }
      if let completed {
        continuation.resume(returning: completed)
        return
      }
      if case .start = command {
        let thread = Thread { self.run() }
        thread.name = "slate.terminal.io"
        thread.start()
      } else {
        notify()
      }
    }
  }

  private func respond(_ result: Result<BackendEvent, ScreenApplicationError>, finished: Bool) {
    let continuation = state.withLock {
      let continuation = $0.continuation
      $0.continuation = nil
      $0.command = nil
      $0.finished = finished
      if finished { $0.result = result }
      return continuation
    }
    continuation?.resume(returning: result)
  }

  private func drainWake() {
    var bytes = InlineArray<64, UInt8>(repeating: 0)
    // At most one pipe capacity is consumed per pass; notifications coalesce.
    for _ in 0..<1_024 {
      var storage = bytes.mutableSpan
      let count = storage.withUnsafeMutableBufferPointer { unsafe read(wakeRead, $0.baseAddress!, $0.count) }
      if count <= 0 { break }
    }
  }

  private func nextCommand() throws(ScreenApplicationError) -> BackendCommand {
    var retries = SystemCallRetryBudget()
    while true {
      drainWake()
      if let command = state.withLock({ $0.command }) { return command }
      var descriptor = pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
      let result = unsafe poll(&descriptor, 1, 50)
      if result < 0 {
        let error = errno
        if retries.retry(after: error) { continue }
        throw .poll(errno: error)
      }
      retries = SystemCallRetryBudget()
    }
  }

  private func run() {
    let result: Result<BackendEvent, ScreenApplicationError>
    do throws(ScreenApplicationError) { result = .success(try session()) } catch { result = .failure(error) }
    respond(result, finished: true)
  }

  private func session() throws(ScreenApplicationError) -> BackendEvent {
    let output: Output
    var terminal: Terminal
    do throws(IOError) {
      output = try Output(fileDescriptor: outputDescriptor, modeWriteTimeout: Self.restorationTimeout)
    } catch { throw .io(error) }
    do throws(TerminalError) { terminal = try Terminal(fileDescriptor: inputDescriptor) } catch {
      throw .terminal(error)
    }
    let rawOutputDescriptor = output.rawDescriptor
    let flags = fcntl(rawOutputDescriptor, F_GETFL)
    guard flags >= 0, fcntl(rawOutputDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw .poll(errno: errno) }
    defer { _ = fcntl(rawOutputDescriptor, F_SETFL, flags) }
    let size: TerminalSize
    do throws(TerminalError) { size = try output.terminalSize() } catch { throw .terminal(error) }
    if case .fail = configuration.viewportOverflow,
      size.columns > configuration.maximumSize.columns || size.rows > configuration.maximumSize.rows
    {
      throw .screen(.viewportCapacityExceeded)
    }
    let signals = try SignalSession(signalHandling)
    let result: BackendEvent
    do throws(ScreenApplicationError) {
      try checkInterruption(signals)
      result = try modes(terminal: &terminal, output: output, signals: signals)
    } catch {
      try? signals.resumeDelivery()
      let number = signals.termination()
      if number != 0 { throw .interrupted(signal: number) }
      throw error
    }
    try signals.resumeDelivery()
    let number = signals.termination()
    if number != 0 { throw .interrupted(signal: number) }
    return result
  }

  private func modes(
    terminal: inout Terminal, output: borrowing Output, signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> BackendEvent {
    let raw: RawMode
    do throws(TerminalError) { raw = try terminal.rawMode() } catch { throw .terminal(error) }
    let alternate: AlternateScreen
    let paste: BracketedPaste
    do throws(IOError) { alternate = try output.alternateScreen() } catch { throw .io(error) }
    do throws(IOError) { paste = try output.bracketedPaste() } catch { throw .io(error) }
    let result = try unicode(input: raw, output: output, signals: signals)
    do throws(IOError) {
      try paste.restore()
      try alternate.restore()
    } catch { throw .io(error) }
    do throws(TerminalError) { try raw.restore() } catch { throw .terminal(error) }
    return result
  }

  private func unicode(
    input: borrowing RawMode, output: borrowing Output, signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> BackendEvent {
    if configuration.capabilities.unicode == .ascii { return try mouse(input: input, output: output, signals: signals) }
    let mode: GraphemeClustering
    do throws(IOError) { mode = try output.graphemeClustering() } catch { throw .io(error) }
    let result = try mouse(input: input, output: output, signals: signals)
    do throws(IOError) { try mode.restore() } catch { throw .io(error) }
    return result
  }

  private func mouse(
    input: borrowing RawMode, output: borrowing Output, signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> BackendEvent {
    guard configuration.mouseTracking else { return try keyboard(input: input, output: output, signals: signals) }
    let mode: MouseTracking
    do throws(IOError) { mode = try output.mouseTracking() } catch { throw .io(error) }
    let result = try keyboard(input: input, output: output, signals: signals)
    do throws(IOError) { try mode.restore() } catch { throw .io(error) }
    return result
  }

  private func keyboard(
    input: borrowing RawMode, output: borrowing Output, signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> BackendEvent {
    guard configuration.enhancedKeyboard else { return try loop(input: input, output: output, signals: signals) }
    let mode: EnhancedKeyboard
    do throws(IOError) { mode = try output.enhancedKeyboard() } catch { throw .io(error) }
    let result = try loop(input: input, output: output, signals: signals)
    do throws(IOError) { try mode.restore() } catch { throw .io(error) }
    return result
  }

  private func loop(
    input: borrowing RawMode, output: borrowing Output, signals: borrowing SignalSession
  ) throws(ScreenApplicationError) -> BackendEvent {
    defer { signals.protectTeardown() }
    try signals.resumeDelivery()
    var event = BackendEvent(
      size: TerminalSize(columns: 0, rows: 0), bytes: InlineArray(repeating: 0), count: 0, endOfInput: false,
      woken: false)
    do throws(TerminalError) { event.size = try output.terminalSize() } catch { throw .terminal(error) }
    var retries = SystemCallRetryBudget()
    var spare = RigidArray<UInt8>(repeating: 0, count: outputBuffer.capacity)
    var needsRecovery = false
    respond(.success(event), finished: false)
    while true {
      let command = try nextCommand()
      switch command {
      case .start: preconditionFailure("A backend starts once")
      case .stop:
        signals.protectTeardown()
        try? recoverOutput(to: output, until: .now.advanced(by: Self.restorationTimeout), needed: &needsRecovery)
        return event
      case .flush, .cleanup:
        let count = outputBuffer.take(into: &spare)
        let bytes = spare.span.extracting(first: count)
        do throws(ScreenApplicationError) {
          if case .cleanup = command {
            try writeCleanup(bytes, to: output, needsRecovery: &needsRecovery)
          } else {
            try writeBatch(bytes, to: output, signals: signals, needsRecovery: &needsRecovery)
          }
          respond(.success(event), finished: false)
        } catch { respond(.failure(error), finished: false) }
      case .poll(let timeout, let generation, let deliverTimeout):
        do throws(ScreenApplicationError) {
          let previousSize = event.size
          while true {
            try checkInterruption(signals)
            let stale = self.generation() != generation
            event = try readEvent(input: input, output: output, timeout: stale ? 0 : timeout)
            try checkInterruption(signals)
            if stale || deliverTimeout || event.woken || event.count > 0 || event.endOfInput
              || event.size != previousSize
            {
              break
            }
          }
          retries = SystemCallRetryBudget()
          respond(.success(event), finished: false)
        } catch {
          let signal = signals.termination()
          if signal != 0 {
            respond(.failure(.interrupted(signal: signal)), finished: false)
            continue
          }
          let interrupted: Bool
          switch error {
          case .poll(let number), .io(.read(let number)): interrupted = number == EINTR
          default: interrupted = false
          }
          if interrupted && retries.retry(after: EINTR) {
            event.count = 0
            event.endOfInput = false
            respond(.success(event), finished: false)
          } else {
            respond(.failure(error), finished: false)
          }
        }
      }
    }
  }

  private func writeBatch(
    _ bytes: Span<UInt8>, to output: borrowing Output, signals: borrowing SignalSession, needsRecovery: inout Bool
  ) throws(ScreenApplicationError) {
    var offset = 0
    defer { needsRecovery = offset > 0 && offset < bytes.count }
    var retries = SystemCallRetryBudget()
    while offset < bytes.count {
      try checkInterruption(signals)
      switch output.writeAvailable(bytes.extracting(droppingFirst: offset)) {
      case .success(let count):
        guard count > 0 else { throw .io(.write(errno: EIO, bytesWritten: offset)) }
        offset += count
        retries = SystemCallRetryBudget()
        continue
      case .failure(.write(let number, _)):
        if retries.retry(after: number) { continue }
        guard number == EAGAIN || number == EWOULDBLOCK else {
          throw .io(.write(errno: number, bytesWritten: offset))
        }
      case .failure(let error): throw .io(error)
      }
      var descriptors: InlineArray<2, pollfd> = [
        pollfd(fd: output.rawDescriptor, events: Int16(POLLOUT), revents: 0),
        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
      ]
      var storage = descriptors.mutableSpan
      let ready = storage.withUnsafeMutableBufferPointer { unsafe poll($0.baseAddress!, 2, 50) }
      if ready < 0 {
        let error = errno
        if retries.retry(after: error) { continue }
        throw .poll(errno: error)
      }
      if descriptors[1].revents != 0 { drainWake() }
      if descriptors[0].revents & Int16(POLLERR | POLLNVAL | POLLHUP) != 0 { throw .disconnected }
    }
  }

  private func writeCleanup(_ bytes: Span<UInt8>, to output: borrowing Output, needsRecovery: inout Bool)
    throws(ScreenApplicationError)
  {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
    do throws(IOError) {
      try recoverOutput(to: output, until: deadline, needed: &needsRecovery)
      try output.writeAll(bytes, until: deadline)
    } catch {
      if case .write(_, let written) = error, written > 0 { needsRecovery = true }
      throw .io(error)
    }
  }

  private func recoverOutput(to output: borrowing Output, until deadline: ContinuousClock.Instant, needed: inout Bool)
    throws(IOError)
  {
    guard needed else { return }
    // CAN and ST close a partial escape before cleanup or terminal restoration.
    let recovery: InlineArray<3, UInt8> = [0x18, 0x1b, 0x5c]
    try output.writeAll(recovery.span, until: deadline)
    needed = false
  }

  private func readEvent(
    input: borrowing RawMode, output: borrowing Output, timeout: Int32
  ) throws(ScreenApplicationError) -> BackendEvent {
    var descriptors: InlineArray<2, pollfd> = [
      pollfd(fd: input.rawDescriptor, events: Int16(POLLIN), revents: 0),
      pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
    ]
    var storage = descriptors.mutableSpan
    let result = storage.withUnsafeMutableBufferPointer { unsafe poll($0.baseAddress!, 2, timeout) }
    if result < 0 { throw .poll(errno: errno) }
    var event = BackendEvent(
      size: TerminalSize(columns: 0, rows: 0), bytes: InlineArray(repeating: 0), count: 0, endOfInput: false,
      woken: false)
    do throws(TerminalError) { event.size = try output.terminalSize() } catch { throw .terminal(error) }
    guard result > 0 else { return event }
    if descriptors[1].revents != 0 {
      event.woken = true
      drainWake()
    }
    if descriptors[0].revents & Int16(POLLERR | POLLNVAL) != 0 { throw .disconnected }
    if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
      do throws(IOError) { event.count = try input.read(into: event.bytes.mutableSpan) } catch {
        if case .read(let number) = error, number == EAGAIN || number == EWOULDBLOCK { return event }
        throw .io(error)
      }
      event.endOfInput = event.count == 0
    }
    return event
  }
}
