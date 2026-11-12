import Slate
import Testing

@testable import SlateGraphicsDemo

@Test func panelDragStartsCenteredAndOnlyCapturesItsTitleBar() {
  let drag = PanelDrag()
  drag.prepare(in: .init(columns: 80, rows: 24))
  #expect(drag.bounds == Rect(x: 25, y: 8, width: 30, height: 7))
  for event in [
    MouseEvent(action: .press, button: .right, column: 30, row: 8),
    MouseEvent(action: .press, button: .left, column: 30, row: 9),
    MouseEvent(action: .press, button: .left, column: 24, row: 8),
    MouseEvent(action: .press, button: .left, column: 55, row: 8)
  ] {
    #expect(drag.handle(event) == .none)
    #expect(!drag.isDragging)
  }
  #expect(drag.handle(.init(action: .press, button: .left, column: 54, row: 8)) == .none)
  #expect(drag.isDragging)
  #expect(drag.handle(.init(action: .move, button: .left, column: 54, row: 8)) == .none)
  #expect(drag.bounds == Rect(x: 25, y: 8, width: 30, height: 7))
}

@Test func panelDragPreservesGrabOffsetAndAppliesFinalReleasePosition() {
  let drag = PanelDrag()
  drag.prepare(in: .init(columns: 80, rows: 24))
  _ = drag.handle(.init(action: .press, button: .left, column: 30, row: 8))
  #expect(drag.handle(.init(action: .move, button: .left, column: 14, row: 5)) == .redraw)
  #expect(drag.bounds == Rect(x: 9, y: 5, width: 30, height: 7))
  #expect(drag.isDragging)
  #expect(drag.handle(.init(action: .release, button: .left, column: 40, row: 10)) == .redraw)
  #expect(drag.bounds == Rect(x: 35, y: 10, width: 30, height: 7))
  #expect(!drag.isDragging)
  #expect(drag.handle(.init(action: .move, button: .left, column: 20, row: 5)) == .none)
}

@Test func panelDragClampsWholePanelAndRecoversFromMissingRelease() {
  let drag = PanelDrag()
  drag.prepare(in: .init(columns: 80, rows: 24))
  _ = drag.handle(.init(action: .press, button: .left, column: 30, row: 8))
  #expect(drag.handle(.init(action: .move, button: .left, column: 65_534, row: 65_534)) == .redraw)
  #expect(drag.bounds == Rect(x: 49, y: 14, width: 30, height: 7))
  #expect(drag.handle(.init(action: .move, button: .left, column: 0, row: 0)) == .redraw)
  #expect(drag.bounds == Rect(x: 1, y: 3, width: 30, height: 7))
  #expect(drag.handle(.init(action: .move, column: 20, row: 10)) == .none)
  #expect(!drag.isDragging)
  #expect(drag.handle(.init(action: .move, button: .left, column: 40, row: 12)) == .none)
  #expect(drag.bounds == Rect(x: 1, y: 3, width: 30, height: 7))
  _ = drag.handle(.init(action: .press, button: .left, column: 4, row: 3))
  #expect(drag.handle(.init(action: .release, column: 20, row: 10)) == .redraw)
  #expect(!drag.isDragging)
  #expect(drag.bounds == Rect(x: 17, y: 10, width: 30, height: 7))
}

@Test func panelDragResizeCancelsCaptureAndClampsRememberedPosition() {
  let drag = PanelDrag()
  drag.prepare(in: .init(columns: 80, rows: 24))
  drag.prepare(in: .init(columns: 100, rows: 40))
  #expect(drag.bounds == Rect(x: 35, y: 16, width: 30, height: 7))
  _ = drag.handle(.init(action: .press, button: .left, column: 40, row: 16))
  _ = drag.handle(.init(action: .move, button: .left, column: 90, row: 30))
  drag.prepare(in: .init(columns: 80, rows: 24))
  #expect(!drag.isDragging)
  #expect(drag.bounds == Rect(x: 49, y: 14, width: 30, height: 7))
  drag.prepare(in: .init(columns: 100, rows: 40))
  #expect(drag.bounds == Rect(x: 49, y: 14, width: 30, height: 7))
  for size in [TerminalSize(columns: 10, rows: 10), .init(columns: 0, rows: 0), .init(columns: 1, rows: 1)] {
    drag.prepare(in: size)
    #expect(drag.bounds.right <= drag.container.right)
    #expect(drag.bounds.bottom <= drag.container.bottom)
    #expect(!drag.isDragging)
  }
  #expect(drag.handle(.init(action: .press, button: .left, column: 1, row: 1)) == .none)
  #expect(!drag.isDragging)
}

@Test func graphicsDemoHidingCancelsDragAndReopeningRetainsPosition() throws {
  var application = SlateGraphicsDemo()
  var copy = CopyBuffer()
  let size = TerminalSize(columns: 80, rows: 24)
  var surface = try Surface(maximumSize: size, nodeCapacity: SlateGraphicsDemo.configuration.nodeCapacity)
  try surface.render(size: size) { application.render(in: size) }
  #expect(SlateGraphicsDemo.configuration.mouseTracking)
  _ = application.event(.mouse(.init(action: .press, button: .left, column: 30, row: 8)), copyBuffer: &copy)
  _ = application.event(.mouse(.init(action: .move, button: .left, column: 14, row: 5)), copyBuffer: &copy)
  let moved = application.overlayBounds
  #expect(application.isDraggingOverlay)
  #expect(application.event(.key(.character("o")), copyBuffer: &copy) == .redraw)
  #expect(!application.isDraggingOverlay && !application.showsOverlay)
  #expect(
    application.event(.mouse(.init(action: .press, button: .left, column: 14, row: 5)), copyBuffer: &copy)
      == .none)
  #expect(!application.isDraggingOverlay)
  _ = application.event(.key(.character("o")), copyBuffer: &copy)
  try surface.render(size: size) { application.render(in: size) }
  #expect(application.overlayBounds == moved)
  _ = application.event(.mouse(.init(action: .press, button: .left, column: 14, row: 5)), copyBuffer: &copy)
  #expect(application.event(.key(.escape), copyBuffer: &copy) == .redraw)
  #expect(!application.isDraggingOverlay && !application.showsOverlay)
  #expect(application.event(.key(.escape), copyBuffer: &copy) == .none)
}

@Test func graphicsDemoDraggingRestoresUncoveredCellsAndMatchesHitGeometry() throws {
  var application = SlateGraphicsDemo()
  var copy = CopyBuffer()
  let size = TerminalSize(columns: 80, rows: 24)
  var surface = try Surface(maximumSize: size, nodeCapacity: SlateGraphicsDemo.configuration.nodeCapacity)
  _ = application.event(.key(.character("o")), copyBuffer: &copy)
  try surface.render(size: size) { application.render(in: size) }
  let background = (0..<(size.columns * size.rows)).map {
    surface.cell(x: $0 % size.columns, y: $0 / size.columns)!
  }
  _ = application.event(.key(.character("o")), copyBuffer: &copy)
  try surface.render(size: size) { application.render(in: size) }
  let original = application.overlayBounds
  #expect(surface.cell(x: original.x, y: original.y)?.glyph.scalar == "┌")
  _ = application.event(.mouse(.init(action: .press, button: .left, column: 30, row: 8)), copyBuffer: &copy)
  _ = application.event(.mouse(.init(action: .move, button: .left, column: 79, row: 23)), copyBuffer: &copy)
  try surface.render(size: size) { application.render(in: size) }
  let moved = application.overlayBounds
  #expect(surface.cell(x: moved.x, y: moved.y)?.glyph.scalar == "┌")
  #expect(surface.cell(x: moved.right - 1, y: moved.bottom - 1)?.glyph.scalar == "┘")
  for y in original.y..<original.bottom {
    for x in original.x..<original.right where x < moved.x || y < moved.y {
      #expect(surface.cell(x: x, y: y) == background[y * size.columns + x])
    }
  }
  let smaller = TerminalSize(columns: 20, rows: 12)
  try surface.render(size: smaller) { application.render(in: smaller) }
  #expect(!application.isDraggingOverlay)
  #expect(application.overlayBounds == Rect(x: 1, y: 3, width: 18, height: 6))
  #expect(surface.cell(x: 1, y: 3)?.glyph.scalar == "┌")
  #expect(surface.cell(x: 18, y: 8)?.glyph.scalar == "┘")
}
