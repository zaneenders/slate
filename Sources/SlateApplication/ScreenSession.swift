import BasicContainers
import Observation
import SlateTerminal
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private final class SessionInvalidation: Sendable {
  private struct State {
    var dirty = true
    var backend: SessionBackend?
  }
  private let state = Mutex(State())
  var backend: SessionBackend? { state.withLock { $0.backend } }
  func connect(_ backend: SessionBackend?) { state.withLock { $0.backend = backend } }
  func invalidate() {
    let backend: SessionBackend? = state.withLock {
      guard !$0.dirty else { return nil }
      $0.dirty = true
      return $0.backend
    }
    backend?.wake()
  }
  func pending() -> Bool { state.withLock { $0.dirty } }
  func take() -> Bool {
    state.withLock {
      let dirty = $0.dirty
      $0.dirty = false
      return dirty
    }
  }
}

/// Owns one terminal worker and a fixed number of application tasks. Rendering and callbacks stay on the main actor.
@MainActor public final class ScreenSession {
  private let outputBuffer: OutputBuffer
  private var tasks: RigidArray<Task<Void, Never>?>
  private var observations: RigidArray<ScreenObservation?>
  private let invalidation = SessionInvalidation()
  private let observation = ScreenObservation()
  private var running = false
  private var quitRequested = false
  private var graphicsInvalidated = false
  private var acceptingTasks = false
  public let maximumOutputBytes: Int
  public let taskCapacity: Int

  /// Fixed output storage is twice maximumOutputBytes; continuation, Observation, and caller payload allocations are outside the rendering guarantee.
  public init(maximumOutputBytes: Int, taskCapacity: Int) {
    precondition(maximumOutputBytes > 0 && maximumOutputBytes <= 64 * 1_048_576)
    precondition(taskCapacity >= 0 && taskCapacity <= 256)
    self.maximumOutputBytes = maximumOutputBytes
    self.taskCapacity = taskCapacity
    outputBuffer = OutputBuffer(capacity: maximumOutputBytes)
    tasks = RigidArray(repeating: nil, count: taskCapacity)
    observations = RigidArray(repeating: nil, count: taskCapacity)
  }

  public func invalidate() { invalidation.invalidate() }

  /// Requests `presentGraphics` and wakes an idle session without invalidating its cell layout.
  public func invalidateGraphics() {
    guard !graphicsInvalidated else { return }
    graphicsInvalidated = true
    invalidation.backend?.wake()
  }

  public func quit() {
    quitRequested = true
    invalidation.backend?.interruptIO()
  }

  /// A busy slot rejects work. Operations must cooperate with cancellation; shutdown cancels and joins every accepted task.
  @discardableResult
  public func startTask(at index: Int, operation: @escaping @MainActor @Sendable () async -> Void) -> Bool {
    precondition(index >= 0 && index < taskCapacity)
    guard acceptingTasks, tasks[index] == nil else { return false }
    tasks[index] = Task {
      await operation()
      if self.acceptingTasks { self.tasks[index] = nil }
    }
    return true
  }

  @discardableResult
  public func consume<Value: Sendable>(
    _ source: ScreenSource<Value>, at index: Int, receive: @escaping @MainActor @Sendable (Value) -> Void
  ) -> Bool {
    startTask(at: index) {
      var delivered = 0
      while let value = await source.next() {
        guard !Task.isCancelled else { return }
        receive(value)
        self.invalidate()
        delivered += 1
        if delivered == 64 {
          delivered = 0
          await Task.yield()
        }
      }
    }
  }

  public func observe(at index: Int, apply: @escaping @MainActor @Sendable () -> Void) -> ScreenObservation? {
    precondition(index >= 0 && index < taskCapacity)
    guard acceptingTasks, tasks[index] == nil else { return nil }
    let observation = ScreenObservation()
    observations[index] = observation
    let accepted = startTask(at: index) {
      let values = Observations {
        observation.track()
        apply()
        return true
      }
      for await _ in values {
        guard !Task.isCancelled else { return }
        self.invalidate()
      }
    }
    precondition(accepted)
    return observation
  }

  public func run<Application: ScreenApplication & ~Copyable>(
    application: inout Application, inputFileDescriptor: Int32, outputFileDescriptor: Int32,
    signalHandling: ScreenSignalHandling
  ) async throws(ScreenApplicationError) {
    precondition(!running, "A session runs one application at a time")
    running = true
    quitRequested = false
    graphicsInvalidated = false
    defer { running = false }
    var runner: ScreenRunner
    do throws(ScreenError) { runner = try ScreenRunner(configuration: Application.configuration) } catch {
      throw .screen(error)
    }
    if let interval = application.tickInterval, interval <= .zero { throw .invalidTickInterval }
    let backend = try SessionBackend(
      inputDescriptor: inputFileDescriptor, outputDescriptor: outputFileDescriptor,
      configuration: Application.configuration, signalHandling: signalHandling, outputBuffer: outputBuffer)
    invalidation.connect(backend)
    defer { invalidation.connect(nil) }
    try await withTaskCancellationHandler { () throws(ScreenApplicationError) in
      try await run(application: &application, runner: &runner, backend: backend)
    } onCancel: {
      backend.interruptIO()
    }
  }

  private func run<Application: ScreenApplication & ~Copyable>(
    application: inout Application, runner: inout ScreenRunner, backend: SessionBackend
  ) async throws(ScreenApplicationError) {
    let output = Output(buffer: outputBuffer)
    var result: Result<Void, ScreenApplicationError> = .success(())
    do throws(ScreenApplicationError) {
      let initial = try await backend.request(.start).get()
      acceptingTasks = true
      application.start(in: self)
      try await loop(application: &application, runner: &runner, backend: backend, output: output, initial: initial)
    } catch {
      if error != .cancelled || !quitRequested || Task.isCancelled { result = .failure(error) }
    }
    acceptingTasks = false
    for index in tasks.indices {
      tasks[index]?.cancel()
      observations[index]?.refresh()
    }
    for index in tasks.indices {
      await tasks[index]?.value
      tasks[index] = nil
      observations[index] = nil
    }
    observation.refresh()
    await application.stop()
    outputBuffer.reset()
    do throws(IOError) { try runner.flushCopies(to: output) } catch {
      if case .success = result { result = .failure(.io(error)) }
    }
    do throws(KittyGraphicsError) { try application.clearGraphics(to: output) } catch {
      if case .success = result { result = .failure(.graphics(error)) }
      try? application.clearGraphics(to: output)
    }
    let cleanup = await backend.request(.cleanup)
    let stopped = await backend.request(.stop)
    if case .failure(.interrupted(let number)) = stopped {
      result = .failure(.interrupted(signal: number))
    } else if case .success = result {
      if Task.isCancelled {
        result = .failure(.cancelled)
      } else if case .failure(let error) = cleanup, error != .cancelled || !quitRequested {
        result = .failure(error)
      } else if case .failure(let error) = stopped, error != .cancelled || !quitRequested {
        result = .failure(error)
      }
    }
    outputBuffer.reset()
    try result.get()
  }

  private func loop<Application: ScreenApplication & ~Copyable>(
    application: inout Application, runner: inout ScreenRunner, backend: SessionBackend,
    output: borrowing Output, initial: BackendEvent
  ) async throws(ScreenApplicationError) {
    var event = initial
    var firstFrame = true
    if let id = Application.configuration.kittyGraphicsQueryID {
      do throws(KittyGraphicsError) { try output.queryKittyGraphics(id: id) } catch { throw .graphics(error) }
    }
    while true {
      if Task.isCancelled { throw .cancelled }
      if quitRequested { return }
      guard runner.update(application: &application) else { return }
      do {
        guard try runner.expireInput(at: .now, application: &application) else { return }
        let receivedAt = ContinuousClock.now
        for offset in stride(from: 0, to: event.count, by: TerminalInput.maximumBatchBytes) {
          let end = min(offset + TerminalInput.maximumBatchBytes, event.count)
          guard try runner.receive(event.bytes.span.extracting(offset..<end), at: receivedAt, application: &application)
          else { return }
        }
        if event.endOfInput {
          runner.finishInput(application: &application)
          return
        }
        if !firstFrame {
          guard runner.performPendingWork(application: &application) else { return }
          guard try runner.tick(at: .now, application: &application) else { return }
        }
      }
      if invalidation.take() { runner.invalidate() }
      var presentedCells = false
      if runner.willDraw(actualSize: event.size) {
        // Retire the previous subscription before tracking all layout and paint reads.
        observation.refresh()
        _ = invalidation.take()
        let statistics: FrameStatistics?
        do throws(ScreenError) {
          let tracked = withObservationTracking { () -> Result<FrameStatistics?, ScreenError> in
            observation.track()
            do throws(ScreenError) {
              return .success(try runner.draw(application: &application, actualSize: event.size, to: output))
            } catch { return .failure(error) }
          } onChange: { [invalidation] in
            invalidation.invalidate()
          }
          statistics = try tracked.get()
        } catch { throw .screen(error) }
        try await flush(backend)
        if let statistics { application.didPresentFrame(statistics) }
        presentedCells = true
      }
      if Task.isCancelled { throw .cancelled }
      if quitRequested { return }
      // Producers may change the model while cells are being written. Rebuild before encoding graphics for that model.
      if (presentedCells || graphicsInvalidated || application.hasPendingGraphics) && !invalidation.pending() {
        graphicsInvalidated = false
        let size: TerminalSize
        do throws(ScreenError) { size = try runner.viewport(for: event.size) } catch { throw .screen(error) }
        do throws(KittyGraphicsError) { try application.presentGraphics(in: size, to: output) } catch {
          throw .graphics(error)
        }
      }
      do throws(IOError) { try runner.flushCopies(to: output) } catch { throw .io(error) }
      try await flush(backend)
      if quitRequested { return }
      firstFrame = false
      event.count = 0
      let generation = backend.generation()
      let pending = invalidation.pending() || graphicsInvalidated
      let timeout = pending ? 0 : try runner.pollTimeout(at: .now, application: application)
      event = try await backend.request(
        .poll(
          timeout, generation,
          deliverTimeout: pending || application.tickInterval != nil || application.hasPendingWork
            || runner.hasInputDeadline,
          readingPaste: runner.canReadLiteralPaste)
      ).get()
    }
  }

  private func flush(_ backend: SessionBackend) async throws(ScreenApplicationError) {
    guard !outputBuffer.isEmpty else { return }
    _ = try await backend.request(.flush).get()
  }

  public func main<Application: ScreenApplication & ~Copyable>(
    application: inout Application, inputFileDescriptor: Int32, outputFileDescriptor: Int32,
    signalHandling: ScreenSignalHandling
  ) async {
    do throws(ScreenApplicationError) {
      try await run(
        application: &application, inputFileDescriptor: inputFileDescriptor,
        outputFileDescriptor: outputFileDescriptor, signalHandling: signalHandling)
    } catch {
      if case .interrupted(let number) = error { exit(128 + number) }
      if case .cancelled = error { return }
      let message = "\(Application.self): \(error)\n"
      if let output = try? Output(fileDescriptor: STDERR_FILENO) { try? output.writeAll(message.utf8Span.span) }
      exit(1)
    }
  }
}
