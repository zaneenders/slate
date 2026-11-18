import CIOTestSupport
import Foundation
import Observation
import SlateTestSupport
import Testing

@testable import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite(.serialized) @MainActor
struct SessionTests {
  @Test func sourcesBoundOrderedDeliveryAndReplaceTelemetry() async {
    let commands = ScreenSource<Int>(policy: .ordered(capacity: 2))
    #expect(commands.publish(10) == .accepted)
    #expect(commands.publish(20) == .accepted)
    #expect(commands.publish(30) == .full)
    #expect(await commands.next() == 10)
    #expect(commands.publish(30) == .accepted)
    #expect(await commands.next() == 20)
    #expect(await commands.next() == 30)
    commands.finish()
    #expect(await commands.next() == nil)
    #expect(commands.publish(40) == .closed)
    let readings = ScreenSource<Int>(policy: .latest)
    #expect(readings.publish(1) == .accepted)
    #expect(readings.publish(2) == .replaced)
    #expect(await readings.next() == 2)
    readings.finish()
  }

  @Test func sourceCancellationWakesItsConsumerAndClosesPublication() async {
    let source = ScreenSource<Int>(policy: .ordered(capacity: 1))
    let consumer = Task { await source.next() }
    await Task.yield()
    consumer.cancel()
    #expect(await consumer.value == nil)
    #expect(source.publish(1) == .closed)
  }

  @Test func canvasReadsObserveAsyncChangesAndShutdownJoinsBoundedTasks() async throws {
    await SessionIOGate.shared.acquire()
    defer { SessionIOGate.shared.release() }
    let pty = try sessionTerminal(columns: 8, rows: 2)
    let saved = try attributes(of: pty.slave)
    let model = SessionTestModel()
    var app = ObservedCanvasApplication(model: model)
    let session = ScreenSession(maximumOutputBytes: 65_536, taskCapacity: 2)
    try await session.run(
      application: &app, inputFileDescriptor: pty.slave,
      outputFileDescriptor: pty.slave, signalHandling: .unchanged)
    #expect(model.frames == 2)
    #expect(model.sawUpdatedFrame)
    #expect(model.rejectedBusyTask)
    #expect(model.producerStopped)
    #expect(model.stopSawJoinedProducer)
    expectEqual(try attributes(of: pty.slave), saved)
  }

  @Test(arguments: [false, true])
  func shutdownRestoresTerminalWhileOutputIsBackpressured(cancel: Bool) async throws {
    await SessionIOGate.shared.acquire()
    defer { SessionIOGate.shared.release() }
    let pty = try sessionTerminal(columns: 240, rows: 80)
    let saved = try attributes(of: pty.slave)
    let session = ScreenSession(maximumOutputBytes: 2 * 1_048_576, taskCapacity: 0)
    let descriptor = pty.slave
    let master = pty.master
    let probe = OutputPressureProbe()
    let task = Task { @MainActor in
      var app = OutputPressureApplication(probe: probe)
      try await session.run(
        application: &app, inputFileDescriptor: descriptor,
        outputFileDescriptor: descriptor, signalHandling: .unchanged)
    }
    defer { task.cancel() }
    #expect(try await waitForSession { probe.painted && outputIsBackpressured(descriptor) })
    if cancel { task.cancel() } else { session.quit() }
    let stopping = try await waitForSession { probe.stopping }
    #expect(stopping)
    if !stopping { task.cancel() }
    // Keep the output queue full through the first restoration attempt.
    try await Task.sleep(for: .milliseconds(20))
    let output = try await Task.detached { try terminalOutput(from: master) }.value
    if cancel {
      await #expect(throws: ScreenApplicationError.cancelled) { try await task.value }
    } else {
      try await task.value
    }
    #expect(output.contains("\u{1b}[?2004l"))
    #expect(output.contains("\u{1b}[?25h\u{1b}[?1049l"))
    expectEqual(try attributes(of: pty.slave), saved)
  }

  @Test func cancellationDuringCleanupReturnsWhileOutputStaysBackpressured() async throws {
    await SessionIOGate.shared.acquire()
    defer { SessionIOGate.shared.release() }
    let pty = try sessionTerminal(columns: 8, rows: 2)
    let saved = try attributes(of: pty.slave)
    let input = try Output(fileDescriptor: pty.master)
    try input.writeAll("q".utf8Span.span)
    let descriptor = pty.slave
    let master = pty.master
    let probe = OutputPressureProbe()
    let session = ScreenSession(maximumOutputBytes: 1_048_576, taskCapacity: 0)
    let task = Task { @MainActor in
      defer { probe.finished = true }
      var app = CleanupPressureApplication(probe: probe)
      try await session.run(
        application: &app, inputFileDescriptor: descriptor,
        outputFileDescriptor: descriptor, signalHandling: .unchanged)
    }
    defer { task.cancel() }
    #expect(try await waitForSession { probe.stopping && outputIsBackpressured(descriptor) })
    task.cancel()
    let finished = try await waitForSession { probe.finished }
    #expect(finished)
    if !finished { _ = try? await Task.detached { try terminalOutput(from: master) }.value }
    await #expect(throws: ScreenApplicationError.cancelled) { try await task.value }
    expectEqual(try attributes(of: pty.slave), saved)
  }

  @Test func outputCapacityFailureRestoresTerminalWithoutGrowingStorage() async throws {
    await SessionIOGate.shared.acquire()
    defer { SessionIOGate.shared.release() }
    let pty = try sessionTerminal(columns: 8, rows: 2)
    let saved = try attributes(of: pty.slave)
    var app = OutputPressureApplication()
    let session = ScreenSession(maximumOutputBytes: 1, taskCapacity: 0)
    await #expect(throws: ScreenApplicationError.screen(.output(.write(errno: ENOBUFS, bytesWritten: 0)))) {
      try await session.run(
        application: &app, inputFileDescriptor: pty.slave,
        outputFileDescriptor: pty.slave, signalHandling: .unchanged)
    }
    expectEqual(try attributes(of: pty.slave), saved)
  }
}

@MainActor private func waitForSession(_ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !condition() {
    if ContinuousClock.now >= deadline { return false }
    try await Task.sleep(for: .milliseconds(5))
  }
  return true
}

private func outputIsBackpressured(_ descriptor: Int32) -> Bool {
  var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
  return unsafe poll(&readiness, 1, 0) == 0
}

private func sessionTerminal(columns: UInt16, rows: UInt16) throws -> PseudoTerminal {
  let pty = try PseudoTerminal()
  var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
  try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
  return pty
}

@MainActor @Observable private final class SessionTestModel {
  var value = 0
  @ObservationIgnored var frames = 0
  @ObservationIgnored var paintedValue = 0
  @ObservationIgnored var sawUpdatedFrame = false
  @ObservationIgnored var rejectedBusyTask = false
  @ObservationIgnored var producerStopped = false
  @ObservationIgnored var stopSawJoinedProducer = false
}

@MainActor private final class ObservedTestDrawing: @MainActor CanvasDrawing {
  let model: SessionTestModel
  init(model: SessionTestModel) { self.model = model }
  func paint(in frame: inout Frame) {
    let value = model.value
    model.paintedValue = value
    frame.fill(frame.area, with: Cell(.space, style: Style(background: value == 0 ? .red : .green)))
  }
}

private struct ObservedCanvasApplication: ScreenApplication {
  let model: SessionTestModel
  let drawing: ObservedTestDrawing
  var session: ScreenSession?
  init(model: SessionTestModel) {
    self.model = model
    drawing = ObservedTestDrawing(model: model)
  }
  mutating func start(in session: ScreenSession) {
    self.session = session
    let model = model
    let accepted = session.startTask(at: 0) {
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
      model.value = 1
    }
    precondition(accepted)
    model.rejectedBusyTask = !session.startTask(at: 0) { Issue.record("A busy slot accepted another task") }
    let producer = session.startTask(at: 1) {
      defer { model.producerStopped = true }
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
    }
    precondition(producer)
  }
  mutating func stop() async { model.stopSawJoinedProducer = model.producerStopped }
  func render(in size: TerminalSize) -> some Block { Canvas(drawing) }
  mutating func didPresentFrame(_ statistics: FrameStatistics) {
    model.frames += 1
    if model.paintedValue == 1 {
      model.sawUpdatedFrame = true
      session?.quit()
    }
  }
}

@MainActor private final class OutputPressureProbe {
  var painted = false
  var stopping = false
  var finished = false
}

private struct OutputPressureApplication: ScreenApplication {
  var probe: OutputPressureProbe? = nil
  func stop() async { probe?.stopping = true }
  func render(in size: TerminalSize) -> some Block { Text("output pressure") }
  func paint(in frame: inout Frame) {
    probe?.painted = true
    for row in 0..<frame.area.height {
      for column in 0..<frame.area.width {
        frame.fill(
          Rect(x: column, y: row, width: 1, height: 1),
          with: Cell(.space, style: Style(background: .rgb(UInt8(column % 256), UInt8(row % 256), 127))))
      }
    }
  }
}

private struct CleanupPressureApplication: ScreenApplication {
  let probe: OutputPressureProbe
  func render(in size: TerminalSize) -> some Block { Text("cleanup pressure") }
  func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(.character("q"), _): return .quit
    default: return .none
    }
  }
  func clearGraphics(to output: borrowing Output) throws(KittyGraphicsError) {
    probe.stopping = true
    let payload = String(repeating: "x", count: 131_072)
    do throws(IOError) { try output.writeAll(payload.utf8Span.span) } catch { throw .output(error) }
  }
}

@Test(arguments: [false, true])
@MainActor func sessionDeliversPendingInputAtEOF(paste: Bool) async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try sessionTerminal(columns: 8, rows: 2)
  let outputDescriptor = pty.slave
  let bytes = paste ? "x\u{1b}[200~partial" : "x\u{1b}"
  #if os(Linux)
  let inputDescriptor = pty.slave
  let inputMaster = pty.master
  cli_test_session_io(inputDescriptor)
  let reads: InlineArray<2, Int32> = [Int32(bytes.utf8.count), 0]
  reads.span.withUnsafeBufferPointer { unsafe cli_test_read_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  #else
  var inputMaster: Int32 = -1
  var inputSlave: Int32 = -1
  try #require(unsafe openpty(&inputMaster, &inputSlave, nil, nil, nil) == 0)
  defer {
    if inputMaster >= 0 { _ = close(inputMaster) }
    _ = close(inputSlave)
  }
  let inputDescriptor = inputSlave
  #endif
  let probe = InputEOFProbe()
  let session = ScreenSession(maximumOutputBytes: 65_536, taskCapacity: 0)
  let task = Task { @MainActor in
    var app = InputEOFApplication(probe: probe)
    try await session.run(
      application: &app, inputFileDescriptor: inputDescriptor,
      outputFileDescriptor: outputDescriptor, signalHandling: .unchanged)
  }
  let watchdog = Task {
    try? await Task.sleep(for: .seconds(4))
    if !Task.isCancelled { task.cancel() }
  }
  defer { watchdog.cancel() }
  #expect(try await waitForSession { probe.presentedInitialFrame })
  #if os(Linux)
  // One extra queued byte makes the second poll readable for the simulated EOF.
  let writer = try Output(fileDescriptor: inputMaster)
  try writer.writeAll((bytes + "z").utf8Span.span)
  #else
  try #require(bytes.withCString { unsafe write(inputMaster, $0, bytes.utf8.count) } == bytes.utf8.count)
  #expect(try await waitForSession { probe.events.first == "x" })
  _ = close(inputMaster)
  inputMaster = -1
  #endif
  try await task.value
  #expect(probe.events == ["x", paste ? "incomplete" : "escape"])
}

@MainActor private final class InputEOFProbe {
  var presentedInitialFrame = false
  var events: [String] = []
}

private struct InputEOFApplication: ScreenApplication {
  let probe: InputEOFProbe
  func render(in size: TerminalSize) -> some Block { Text("EOF") }
  func didPresentFrame(_ statistics: FrameStatistics) { probe.presentedInitialFrame = true }
  func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(.character(let scalar), _): probe.events.append(String(scalar))
    case .key(.escape, _): probe.events.append("escape")
    case .pasteRejected(.incomplete): probe.events.append("incomplete")
    default: Issue.record("Unexpected input event")
    }
    return .none
  }
}

@Test @MainActor func graphicsOnlyUpdatesReuseThePresentedCellFrame() async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try sessionTerminal(columns: 8, rows: 2)
  let probe = GraphicsOnlyProbe()
  var app = GraphicsOnlyApplication(probe: probe)
  let session = ScreenSession(maximumOutputBytes: 65_536, taskCapacity: 0)
  try await session.run(
    application: &app, inputFileDescriptor: pty.slave,
    outputFileDescriptor: pty.slave, signalHandling: .unchanged)
  #expect(probe.cellFrames == 1)
  #expect(probe.graphicsBatches == 3)
}

@Test @MainActor func graphicsInvalidationWakesAnIdleSessionWithoutDrawingCells() async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try sessionTerminal(columns: 8, rows: 2)
  let descriptor = pty.slave
  let probe = GraphicsOnlyProbe()
  let session = ScreenSession(maximumOutputBytes: 65_536, taskCapacity: 0)
  let task = Task { @MainActor in
    var app = GraphicsOnlyApplication(probe: probe, usesTicks: false)
    try await session.run(
      application: &app, inputFileDescriptor: descriptor,
      outputFileDescriptor: descriptor, signalHandling: .unchanged)
  }
  defer { task.cancel() }
  #expect(try await waitForSession { probe.graphicsBatches == 1 })
  try await Task.sleep(for: .milliseconds(75))
  session.invalidateGraphics()
  session.invalidateGraphics()
  #expect(try await waitForSession { probe.graphicsBatches == 2 })
  session.quit()
  try await task.value
  #expect(probe.cellFrames == 1)
  #expect(probe.graphicsBatches == 2)
}

@MainActor private final class GraphicsOnlyProbe {
  var cellFrames = 0
  var graphicsBatches = 0
  var pending = false
}

private struct GraphicsOnlyApplication: ScreenApplication {
  let probe: GraphicsOnlyProbe
  let usesTicks: Bool
  private var session: ScreenSession?
  init(probe: GraphicsOnlyProbe, usesTicks: Bool = true) {
    self.probe = probe
    self.usesTicks = usesTicks
  }
  var tickInterval: Duration? { usesTicks ? .milliseconds(1) : nil }
  var hasPendingGraphics: Bool { probe.pending }
  mutating func start(in session: ScreenSession) { self.session = session }
  func render(in size: TerminalSize) -> some Block { Text("cells") }
  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .tick: probe.pending = true
    default: break
    }
    return .none
  }
  mutating func didPresentFrame(_ statistics: FrameStatistics) { probe.cellFrames += 1 }
  mutating func presentGraphics(in size: TerminalSize, to output: borrowing Output) throws(KittyGraphicsError) {
    probe.pending = false
    probe.graphicsBatches += 1
    try output.deleteKittyImage(id: 1)
    if probe.graphicsBatches == 3 { session?.quit() }
  }
}

@Test @MainActor func sourceWakeSynchronizesCachedWidgetsBeforeDrawingWithoutATimer() async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try sessionTerminal(columns: 8, rows: 2)
  let probe = CachedWidgetProbe()
  var app = CachedWidgetApplication(probe: probe)
  let session = ScreenSession(maximumOutputBytes: 65_536, taskCapacity: 2)
  try await session.run(
    application: &app, inputFileDescriptor: pty.slave,
    outputFileDescriptor: pty.slave, signalHandling: .unchanged)
  #expect(probe.frames == 2)
  #expect(probe.rendered == 7)
}

@MainActor private final class CachedWidgetProbe {
  var received = 0
  var cached = 0
  var rendered = 0
  var frames = 0
}

private struct CachedWidgetApplication: ScreenApplication {
  let probe: CachedWidgetProbe
  private var session: ScreenSession?
  init(probe: CachedWidgetProbe) { self.probe = probe }
  mutating func start(in session: ScreenSession) {
    self.session = session
    let probe = probe
    let source = ScreenSource<Int>(policy: .latest)
    let consumer = session.consume(source, at: 0) { probe.received = $0 }
    let producer = session.startTask(at: 1) {
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
      source.publish(7)
    }
    precondition(consumer && producer)
  }
  mutating func update(copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    guard probe.received != probe.cached else { return .none }
    probe.cached = probe.received
    return .redraw
  }
  func render(in size: TerminalSize) -> some Block {
    probe.rendered = probe.cached
    return Text("\(probe.cached)")
  }
  mutating func didPresentFrame(_ statistics: FrameStatistics) {
    probe.frames += 1
    if probe.rendered == 7 { session?.quit() }
  }
}

#if os(Linux)
@Test @MainActor func partialGraphicsWriteCancelsFramingBeforeImageAndTerminalCleanup() async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try sessionTerminal(columns: 8, rows: 2)
  cli_test_session_io(pty.slave)
  let steps: InlineArray<6, Int32> = [4_096, 4_096, 4_096, 4_096, 3, -EIO]
  steps.span.withUnsafeBufferPointer { unsafe cli_test_write_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  var app = PartialGraphicsApplication()
  let session = ScreenSession(maximumOutputBytes: 65_536, taskCapacity: 0)
  await #expect(throws: ScreenApplicationError.io(.write(errno: EIO, bytesWritten: 3))) {
    try await session.run(
      application: &app, inputFileDescriptor: pty.slave,
      outputFileDescriptor: pty.slave, signalHandling: .unchanged)
  }
  let output = try terminalOutput(from: pty.master)
  #expect(output.contains("\u{1b}_G\u{18}\u{1b}\\"))
  let deletion = try #require(output.range(of: "\u{1b}_Ga=d,d=I,i=1,q=2\u{1b}\\"))
  let restoration = try #require(output.range(of: "\u{1b}[?1049l"))
  #expect(deletion.upperBound < restoration.lowerBound)
}

private struct PartialGraphicsApplication: ScreenApplication {
  func render(in size: TerminalSize) -> some Block { Text("cells") }
  mutating func presentGraphics(in size: TerminalSize, to output: borrowing Output) throws(KittyGraphicsError) {
    do throws(IOError) { try output.writeAll("\u{1b}_Gpayload\u{1b}\\".utf8Span.span) } catch { throw .output(error) }
  }
  mutating func clearGraphics(to output: borrowing Output) throws(KittyGraphicsError) {
    try output.deleteKittyImage(id: 1)
  }
}
#endif
