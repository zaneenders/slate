import Slate
import SlateGamepad
import SlateTestSupport
import Testing

@testable import SlateNavigationDemo

@Test func navigationDemoControllerUsesFocusEditingAndSafeBack() throws {
  var application = SlateNavigationDemo()
  application.page = .sources
  var surface = try Surface(maximumSize: .init(columns: 80, rows: 24))
  let size = surface.maximumSize
  try surface.render(size: size) { application.render(in: size) }
  var copy = CopyBuffer()
  #expect(application.focus.focus(.sources))
  #expect(application.handleController(.move(.right), copyBuffer: &copy) == .redraw)
  #expect(application.focus.focusedID == .input)
  #expect(application.handleController(.activate, copyBuffer: &copy) == .redraw)
  #expect(application.editing == true)
  let cursor = application.input.cursorByteOffset
  _ = application.handleController(.move(.left), copyBuffer: &copy)
  #expect(application.input.cursorByteOffset < cursor && application.focus.focusedID == .input)
  #expect(application.handleController(.back, copyBuffer: &copy) == .redraw)
  #expect(application.editing == false && application.focus.focusedID == .input)
  _ = application.handleController(.back, copyBuffer: &copy)
  #expect(application.focus.focusedID == .sources)
  // Back remains safe even when already in the sidebar; quitting is explicit.
  #expect(application.handleController(.back, copyBuffer: &copy) == .redraw)
  #expect(application.event(.key(.control(.q)), copyBuffer: &copy) == .quit)
}

@Test func navigationDemoControllerDefersMovementUntilPageGeometryCommits() throws {
  var application = SlateNavigationDemo()
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 80, rows: 24)
  var screen = try Screen(maximumSize: size)
  _ = try screen.draw(size: size, to: output) { application.render(in: size) }
  var copy = CopyBuffer()
  #expect(application.focus.focus(.sources))
  _ = application.handleController(.activate, copyBuffer: &copy)
  _ = application.handleController(.move(.right), copyBuffer: &copy)
  #expect(application.focus.focusedID == .sources)
  #expect(application.hasPendingWork == false)
  let statistics = try screen.draw(size: size, to: output) { application.render(in: size) }
  application.didPresentFrame(statistics)
  #expect(application.hasPendingWork == true)
  _ = application.performPendingWork()
  #expect(application.focus.focusedID == .input)
}

@Test func navigationDemoControllerInstructionsReflowAndAnimationKeepsItsCadence() throws {
  var application = SlateNavigationDemo()
  // Render instructions without opening a hardware reader from the test thread.
  application.controllerEnabled = true
  #expect(application.tickInterval == .milliseconds(16))
  var surface = try Surface(maximumSize: .init(columns: 100, rows: 40))
  for size in [surface.maximumSize, .init(columns: 44, rows: 36), .init(columns: 1, rows: 1)] {
    try surface.render(size: size) { application.render(in: size) }
  }
  application.controllerEnabled = false
  var copy = CopyBuffer()
  let phase = application.signal.phase
  for _ in 0..<6 { _ = application.event(.tick(elapsed: .milliseconds(16)), copyBuffer: &copy) }
  #expect(application.signal.phase == phase)
  _ = application.event(.tick(elapsed: .milliseconds(16)), copyBuffer: &copy)
  #expect(application.signal.phase == (phase + 2) % 64)
  _ = application.handleController(.pause, copyBuffer: &copy)
  #expect(application.animating == false)
  #expect(application.tickInterval == nil)
}
