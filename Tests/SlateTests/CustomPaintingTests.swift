import Slate
import Testing

@testable import SlateApplication

@Test func applicationCustomPaintingParticipatesInNormalRedrawAndDiffing() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var runner = try ScreenRunner(configuration: .init())
  var application = PaintingApplication()
  let size = TerminalSize(columns: 2, rows: 1)
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.calls == 1)
  #expect(try capture.take() == Array("\u{1b}[0m\u{1b}[2J\u{1b}[1;1H\u{1b}[0mxB\u{1b}[0m".utf8))
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.calls == 1)
  #expect(try capture.take().isEmpty)
  #expect(runner.receive("r".utf8Span.span, at: .now, application: &application))
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.calls == 2)
  #expect(try capture.take().isEmpty)
}

private final class PaintProbe {
  var calls = 0
}

private struct PaintingApplication: ScreenApplication {
  let probe = PaintProbe()

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key: return .redraw
    default: return .none
    }
  }

  func render(in size: TerminalSize) -> some Block { Text("AB") }

  func paint(in frame: inout Frame) {
    probe.calls += 1
    frame[0, 0] = Cell(Glyph("x")!)
  }
}
