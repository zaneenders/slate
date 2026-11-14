import Slate
import SlateGamepad
import Testing

@testable import SlateNavigationDemo

@Test func navigationDemoReflowsFocusGroupsAndAcceptsMouseSelection() throws {
  var app = SlateNavigationDemo()
  app.controllerEnabled = false
  var surface = try Surface(maximumSize: .init(columns: 100, rows: 40))
  var copy = CopyBuffer()
  for size in [TerminalSize(columns: 80, rows: 24), .init(columns: 44, rows: 36)] {
    try surface.render(size: size) { app.render(in: size) }
    _ = app.focus.focus(size.columns >= 54 ? .cyan : .pause)
    #expect(app.focus.move(size.columns >= 54 ? .right : .down))
    #expect(app.focus.isFocused(.input))
    let bounds = try #require(app.focus.bounds(for: .magenta))
    #expect(
      app.event(
        .mouse(.init(action: .press, button: .left, column: bounds.x, row: bounds.y)),
        copyBuffer: &copy) == .redraw)
    #expect(app.focus.isFocused(.magenta) && app.drawing.color == .magenta)
    #expect(app.editing == false)
    try surface.render(size: size) { app.render(in: size) }
    let hasDrawing = (0..<size.rows).contains { row in
      (0..<size.columns).contains { column in surface.cell(x: column, y: row)?.style.background == .magenta }
    }
    #expect(hasDrawing)
  }
  try surface.render(size: .init(columns: 1, rows: 1)) { app.render(in: .init(columns: 1, rows: 1)) }
}

@Test func navigationDemoEditingKeepsArrowsAndClipboardWithTheInput() throws {
  var app = SlateNavigationDemo()
  app.controllerEnabled = false
  var surface = try Surface(maximumSize: .init(columns: 80, rows: 24))
  let size = surface.maximumSize
  try surface.render(size: size) { app.render(in: size) }
  _ = app.focus.focus(.input)
  var copy = CopyBuffer()
  _ = app.handleController(.activate, copyBuffer: &copy)
  #expect(app.editing == true)
  let cursor = app.input.cursorByteOffset
  _ = app.handleController(.move(.left), copyBuffer: &copy)
  #expect(app.input.cursorByteOffset == cursor - 1 && app.focus.isFocused(.input))
  _ = app.event(.key(.character("a"), modifiers: .control), copyBuffer: &copy)
  _ = app.event(.paste("hello 漢".utf8Span), copyBuffer: &copy)
  #expect(app.input.snapshot() == "hello 漢")
  _ = app.event(.key(.character("a"), modifiers: .control), copyBuffer: &copy)
  #expect(app.event(.key(.character("c"), modifiers: .control), copyBuffer: &copy) == .redraw)
  var copied = ""
  copy.flush { copied = String(copying: $0) }
  #expect(copied == "hello 漢")
  _ = app.handleController(.activate, copyBuffer: &copy)
  #expect(app.editing == false)
  #expect(app.event(.key(.character("q"), modifiers: .control), copyBuffer: &copy) == .quit)
}

@Test func navigationDemoControllerBackAndPauseAndAnimation() throws {
  var app = SlateNavigationDemo()
  app.controllerEnabled = false
  var surface = try Surface(maximumSize: .init(columns: 80, rows: 24))
  let size = surface.maximumSize
  try surface.render(size: size) { app.render(in: size) }
  var copy = CopyBuffer()
  _ = app.focus.focus(.input)
  _ = app.handleController(.activate, copyBuffer: &copy)
  _ = app.handleController(.back, copyBuffer: &copy)
  #expect(app.editing == false && app.focus.isFocused(.cyan))
  #expect(app.event(.tick(elapsed: .milliseconds(100)), copyBuffer: &copy) == .redraw)
  #expect(app.drawing.phase == 1)
  _ = app.handleController(.pause, copyBuffer: &copy)
  #expect(app.animating == false && app.tickInterval == nil)
  #expect(app.event(.tick(elapsed: .seconds(1)), copyBuffer: &copy) == .none)
  #expect(app.drawing.phase == 1)
  app.controllerEnabled = true
  #expect(app.tickInterval == .milliseconds(16))
}
