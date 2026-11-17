import CIOTestSupport
import SlateTestSupport
import Testing

@testable import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test @MainActor func frameObservationReportsSuccessfulDiffsAndResizesButSkipsIdleDraws() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var runner = try ScreenRunner(configuration: .init())
  var application = ObservingApplication()
  let size = TerminalSize(columns: 2, rows: 1)
  #expect(try presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output))
  #expect(application.frames.count == 1 && application.frames[0].changedCells == 2)
  #expect(application.frames[0].outputBytes == (try capture.take()).count)
  #expect(try !presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output))
  #expect(application.frames.count == 1)
  #expect(try runner.receive("r".utf8Span.span, at: .now, application: &application))
  #expect(try presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output))
  #expect(application.frames.last?.changedCells == 0 && application.frames.last?.outputBytes == 0)
  #expect(try capture.take().isEmpty)
  application.text = "Ax"
  #expect(try runner.receive("r".utf8Span.span, at: .now, application: &application))
  #expect(try presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output))
  #expect(application.frames.last?.changedCells == 1)
  #expect(application.frames.last?.outputBytes == (try capture.take()).count)
  #expect(
    try presentTestFrame(runner: &runner, application: &application, actualSize: .init(columns: 1, rows: 1), to: output)
  )
  #expect(application.frames.count == 4)
  #expect(application.frames.last?.changedCells == 1)
  #expect(application.frames.last?.outputBytes == (try capture.take()).count)
}

@Test @MainActor func frameObservationSkipsLayoutFailuresAndAllowsSuccessfulRetry() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var runner = try ScreenRunner(configuration: .init())
  var application = ObservingApplication()
  application.text = String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1)
  #expect(throws: ScreenError.layout(.textTooLong)) {
    try presentTestFrame(runner: &runner, application: &application, actualSize: .init(columns: 2, rows: 1), to: output)
  }
  #expect(application.frames.isEmpty)
  #expect(try capture.take().isEmpty)
  application.text = "ok"
  #expect(
    try presentTestFrame(runner: &runner, application: &application, actualSize: .init(columns: 2, rows: 1), to: output)
  )
  #expect(application.frames.count == 1)
}

#if os(Linux)
@Test @MainActor func frameObservationSkipsPartialOutputFailuresAndReportsTheRetry() async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var runner = try ScreenRunner(configuration: .init())
  var application = ObservingApplication()
  let size = TerminalSize(columns: 2, rows: 1)
  let steps: InlineArray<2, Int32> = [3, -EAGAIN]
  steps.span.withUnsafeBufferPointer { unsafe cli_test_write_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  #expect(throws: ScreenError.output(.write(errno: EAGAIN, bytesWritten: 3))) {
    try presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output)
  }
  #expect(application.frames.isEmpty)
  #expect(try capture.take().count == 3)
  #expect(try presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output))
  #expect(application.frames.count == 1 && application.frames[0].changedCells == 2)
  #expect(application.frames[0].outputBytes == (try capture.take()).count)
}
#endif

private struct ObservingApplication: ScreenApplication, ~Copyable {
  var text = "AB"
  var frames: [FrameStatistics] = []

  mutating func didPresentFrame(_ statistics: FrameStatistics) { frames.append(statistics) }
  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate { .redraw }
  func render(in size: TerminalSize) -> some Block { Text(text) }
}
