import SlateTerminal
import SlateTestSupport
import Testing

@Test func canvasPresentationDiffsOwnerChangesWithoutTouchingSiblings() throws {
  let drawing = ColorCanvas()
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 6, rows: 2)
  var screen = try Screen(maximumSize: size)
  func content() -> some Block {
    Row {
      Text("L").frame(width: .fixed(1))
      Canvas(drawing)
      Text("R").frame(width: .fixed(1))
    }
  }
  try screen.draw(size: size, to: output, content: content)
  _ = try capture.take()
  #expect(try screen.draw(size: size, to: output, content: content).outputBytes == 0)
  #expect(try capture.take().isEmpty)

  drawing.color = .red
  let changed = try screen.draw(size: size, to: output, content: content)
  #expect(changed.changedCells == 8)
  #expect(changed.outputBytes == (try capture.take()).count)
  #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "L")
  #expect(screen.cell(x: 5, y: 0)?.glyph.scalar == "R")
  for y in 0..<2 {
    for x in 1..<5 { #expect(screen.cell(x: x, y: y)?.style.background == .red) }
  }
}

private final class ColorCanvas: CanvasDrawing {
  var color = Color.blue
  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: color)))
  }
}
