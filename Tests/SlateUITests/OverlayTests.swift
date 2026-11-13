import SlateUI
import Testing

@Test func overlayPaintsBackToFrontAndPreservesUntouchedCells() throws {
  let back = OverlayDrawing { $0.fill($0.area, with: Cell(Glyph(".")!)) }
  let middle = OverlayDrawing { $0.fill($0.area, with: Cell(Glyph("#")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 6, rows: 3))
  try surface.render(size: surface.maximumSize) {
    Overlay(alignment: .center) {
      Canvas(back)
      Canvas(middle).frame(width: .fixed(4), height: .fixed(2))
      Text("ok")
    }
  }
  #expect(overlayRow(surface, y: 0) == ".####.")
  #expect(overlayRow(surface, y: 1) == ".#ok#.")
  #expect(overlayRow(surface, y: 2) == "......")
  #expect(back.area == Rect(width: 6, height: 3))
  #expect(middle.area == Rect(width: 4, height: 2))
}

@Test func overlayAlignsAllNinePositions() throws {
  let positions: [(Alignment, Int, Int)] = [
    (.topLeading, 0, 0), (.top, 2, 0), (.topTrailing, 4, 0),
    (.leading, 0, 1), (.center, 2, 1), (.trailing, 4, 1),
    (.bottomLeading, 0, 2), (.bottom, 2, 2), (.bottomTrailing, 4, 2)
  ]
  var surface = try Surface(maximumSize: TerminalSize(columns: 5, rows: 3))
  for (alignment, expectedX, expectedY) in positions {
    try surface.render(size: surface.maximumSize) { Overlay(alignment: alignment) { Text("x") } }
    for y in 0..<3 {
      for x in 0..<5 {
        let expected: Unicode.Scalar = x == expectedX && y == expectedY ? "x" : " "
        #expect(surface.cell(x: x, y: y)?.glyph.scalar == expected)
      }
    }
  }
}

@Test func overlayKeepsDecoratedPopupAtItsNaturalSize() throws {
  let back = OverlayDrawing { $0.fill($0.area, with: Cell(Glyph(".")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 9, rows: 5))
  try surface.render(size: surface.maximumSize) {
    Overlay(alignment: .center) {
      Canvas(back)
      Text("X").padding(1).border().background(.blue)
    }
  }
  #expect(overlayRow(surface, y: 0) == "..┌───┐..")
  #expect(overlayRow(surface, y: 2) == "..│ X │..")
  #expect(overlayRow(surface, y: 4) == "..└───┘..")
  #expect(surface.cell(x: 1, y: 2)?.style.background == .default)
  #expect(surface.cell(x: 4, y: 2)?.style.background == .blue)
}

@Test func overlayVisibilityRestoresUnderlyingDrawingWithoutGrowingStorage() throws {
  let back = OverlayDrawing { $0.fill($0.area, with: Cell(Glyph("b")!, style: Style(background: .blue))) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 2))
  let budget = surface.storageBudgetBytes
  for visible in [false, true, false, true, false] {
    try surface.render(size: surface.maximumSize) {
      Overlay(alignment: .bottomTrailing) {
        Canvas(back)
        if visible { Text("X").background(.red) }
      }
    }
    #expect(overlayRow(surface, y: 0) == "bbbb")
    #expect(overlayRow(surface, y: 1) == (visible ? "bbbX" : "bbbb"))
    #expect(surface.cell(x: 2, y: 1)?.style.background == .blue)
    #expect(surface.cell(x: 3, y: 1)?.style.background == (visible ? .red : .blue))
    #expect(surface.storageBudgetBytes == budget)
  }
}

@Test func overlayClipsCanvasAndRepairsStraddlingWideGlyphs() throws {
  let style = Style(foreground: .cyan, background: .blue)
  let back = OverlayDrawing { $0.text("漢漢漢", in: $0.area, style: style) }
  let front = OverlayDrawing { $0.fill(Rect(width: 100, height: 100), with: Cell(Glyph("x")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 6, rows: 1))
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Canvas(back)
      Canvas(front).frame(width: .fixed(2), height: .fixed(1)).padding(horizontal: 1)
    }
  }
  #expect(front.area == Rect(width: 2, height: 1))
  #expect(surface.cell(x: 0, y: 0) == Cell(style: style))
  #expect(surface.cell(x: 1, y: 0)?.glyph.scalar == "x")
  #expect(surface.cell(x: 2, y: 0)?.glyph.scalar == "x")
  #expect(surface.cell(x: 3, y: 0) == Cell(style: style))
  #expect(surface.cell(x: 4, y: 0)?.glyph == Glyph("漢"))
  #expect(surface.cell(x: 5, y: 0)?.isContinuation == true)
}

@Test func overlayLayoutFailurePreservesTheLastFrameAndAllowsReuse() throws {
  let drawing = OverlayDrawing { $0.text("keep", in: $0.area) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 1))
  let initialBudget = surface.storageBudgetBytes
  try surface.render(size: surface.maximumSize) { Overlay { Canvas(drawing) } }
  #expect(throws: SurfaceError.layout(.textTooLong)) {
    try surface.render(size: surface.maximumSize) {
      Overlay {
        Canvas(drawing)
        Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
      }
    }
  }
  #expect(drawing.calls == 1)
  #expect(overlayRow(surface, y: 0) == "keep")
  let budget = surface.storageBudgetBytes
  #expect(budget == initialBudget)
  try surface.render(size: surface.maximumSize) { Overlay { Text("next") } }
  #expect(overlayRow(surface, y: 0) == "next")
  try surface.render(size: surface.maximumSize) { Overlay {} }
  #expect(overlayRow(surface, y: 0) == "    ")
  try surface.render(size: TerminalSize(columns: 0, rows: 0)) { Overlay { Canvas(drawing) } }
  #expect(surface.storageBudgetBytes == budget)
  #expect(drawing.calls == 1)
}

private final class OverlayDrawing: CanvasDrawing {
  private let operation: (inout Frame) -> Void
  private(set) var calls = 0
  private(set) var area: Rect?
  init(_ operation: @escaping (inout Frame) -> Void) { self.operation = operation }
  func paint(in frame: inout Frame) {
    calls += 1
    area = frame.area
    operation(&frame)
  }
}

private func overlayRow(_ surface: borrowing Surface, y: Int) -> String {
  String((0..<surface.size.columns).map { Character(surface.cell(x: $0, y: y)!.glyph.scalar) })
}
