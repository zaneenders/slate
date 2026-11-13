import SlateUI
import Testing

@Test func positionUsesParentLocalCoordinatesWithoutMovingOtherLayersOrSiblings() throws {
  let back = PositionDrawing { $0.fill($0.area, with: Cell(Glyph(".")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 12, rows: 7))
  try surface.render(size: surface.maximumSize) {
    Column {
      Text("header")
      Overlay(alignment: .center) {
        Canvas(back)
        Text("XY").position(column: 3, row: 1)
        Text("Z")
      }.frame(width: .fill, height: .fill)
      Text("footer")
    }
  }
  #expect(back.area == Rect(width: 12, height: 5))
  #expect(positionRow(surface, y: 0) == "header      ")
  #expect(positionRow(surface, y: 1) == "............")
  #expect(positionRow(surface, y: 2) == "...XY.......")
  #expect(positionRow(surface, y: 3) == ".....Z......")
  #expect(positionRow(surface, y: 6) == "footer      ")
}

@Test func positionKeepsDecoratedContentAtItsNaturalSize() throws {
  let back = PositionDrawing { $0.fill($0.area, with: Cell(Glyph(".")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 11, rows: 8))
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Canvas(back)
      Text("X").padding(1).border().background(.blue).position(column: 4, row: 2)
    }
  }
  #expect(positionRow(surface, y: 1) == "...........")
  #expect(positionRow(surface, y: 2) == "....┌───┐..")
  #expect(positionRow(surface, y: 4) == "....│ X │..")
  #expect(positionRow(surface, y: 6) == "....└───┘..")
  #expect(positionRow(surface, y: 7) == "...........")
  #expect(surface.cell(x: 3, y: 4)?.style.background == .default)
  #expect(surface.cell(x: 6, y: 4)?.style.background == .blue)
}

@Test func positionClampsBothAxesBeforeAddingANestedParentOriginAndClipsPainting() throws {
  let back = PositionDrawing { $0.fill($0.area, with: Cell(Glyph(".")!)) }
  let front = PositionDrawing { $0.fill(Rect(width: 100, height: 100), with: Cell(Glyph("x")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 13, rows: 7))
  try surface.render(size: surface.maximumSize) {
    Row {
      Text("L").frame(width: .fixed(2), alignment: .topLeading)
      Overlay {
        Canvas(back)
        Canvas(front).frame(width: .fixed(3), height: .fixed(2))
          .position(column: 65_535, row: 65_535)
      }.padding(1).border().frame(width: .fixed(10), height: .fixed(7))
      Text("R")
    }
  }
  #expect(back.area == Rect(width: 6, height: 3))
  #expect(front.area == Rect(width: 3, height: 2))
  #expect(positionRow(surface, y: 0) == "L ┌────────┐R")
  #expect(positionRow(surface, y: 2) == "  │ ...... │ ")
  #expect(positionRow(surface, y: 3) == "  │ ...xxx │ ")
  #expect(positionRow(surface, y: 4) == "  │ ...xxx │ ")
  #expect(positionRow(surface, y: 6) == "  └────────┘ ")
}

@Test func positionUsesOneClampedOriginForAllChildrenOfACustomBlock() throws {
  let back = PositionDrawing { $0.fill($0.area, with: Cell(Glyph(".")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 8, rows: 4))
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Canvas(back)
      PositionMultipleChildren().position(column: 65_535, row: 65_535)
    }
  }
  #expect(positionRow(surface, y: 1) == "........")
  #expect(positionRow(surface, y: 2) == "....xBCD")
  #expect(positionRow(surface, y: 3) == "....EFGH")
}

@Test func positionKeepsFilledAxesAtTheParentOrigin() throws {
  let back = PositionDrawing { $0.fill($0.area, with: Cell(Glyph(".")!)) }
  let front = PositionDrawing { $0.fill($0.area, with: Cell(Glyph("x")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 5, rows: 3))
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Canvas(back)
      Canvas(front).frame(width: .fixed(2), height: .fill).position(column: 65_535, row: 65_535)
    }
  }
  #expect(front.area == Rect(width: 2, height: 3))
  for y in 0..<3 { #expect(positionRow(surface, y: y) == "...xx") }

  try surface.render(size: surface.maximumSize) {
    Overlay {
      Canvas(back)
      Canvas(front).position(column: 65_535, row: 65_535)
    }
  }
  #expect(front.area == Rect(width: 5, height: 3))
  for y in 0..<3 { #expect(positionRow(surface, y: y) == "xxxxx") }
}

@Test func positionResolvesOversizedAndEmptyContentAcrossViewportResizesWithoutGrowingStorage() throws {
  let back = PositionDrawing { $0.fill($0.area, with: Cell(Glyph(".")!)) }
  let front = PositionDrawing { $0.fill($0.area, with: Cell(Glyph("x")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 6, rows: 4))
  let budget = surface.storageBudgetBytes
  let sizes = [
    TerminalSize(columns: 6, rows: 4), TerminalSize(columns: 2, rows: 1),
    TerminalSize(columns: 1, rows: 1), TerminalSize(columns: 0, rows: 4),
    TerminalSize(columns: 6, rows: 0), TerminalSize(columns: 0, rows: 0),
    TerminalSize(columns: 6, rows: 4)
  ]
  var expectedCalls = 0
  for size in sizes {
    try surface.render(size: size) {
      Overlay {
        Canvas(back)
        Canvas(front).frame(width: .fixed(5), height: .fixed(3))
          .position(column: 65_535, row: 65_535)
      }
    }
    if size.columns > 0 && size.rows > 0 {
      expectedCalls += 1
      #expect(front.area == Rect(width: min(5, size.columns), height: min(3, size.rows)))
      let originColumn = max(0, size.columns - 5)
      let originRow = max(0, size.rows - 3)
      for y in 0..<size.rows {
        for x in 0..<size.columns {
          let expected: Unicode.Scalar = x >= originColumn && y >= originRow ? "x" : "."
          #expect(surface.cell(x: x, y: y)?.glyph.scalar == expected)
        }
      }
    }
    #expect(front.calls == expectedCalls)
    #expect(back.calls == expectedCalls)
    #expect(surface.size == size)
    #expect(surface.storageBudgetBytes == budget)
  }
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Canvas(back)
      Canvas(front).frame(width: .fixed(0), height: .fixed(3)).position(column: 65_535, row: 65_535)
    }
  }
  #expect(front.calls == expectedCalls)
  for y in 0..<4 { #expect(positionRow(surface, y: y) == "......") }
}

@Test func positionMovementRestoresUnderlyingCellsAndRepairsWideGlyphClipEdges() throws {
  let style = Style(foreground: .cyan, background: .blue)
  let back = PositionDrawing { $0.text("漢漢漢", in: $0.area, style: style) }
  let front = PositionDrawing { $0.fill(Rect(width: 100, height: 100), with: Cell(Glyph("x")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 6, rows: 1))
  for column in [1, 3] {
    try surface.render(size: surface.maximumSize) {
      Overlay {
        Canvas(back)
        Canvas(front).frame(width: .fixed(2), height: .fixed(1)).position(column: column, row: 0)
      }
    }
    #expect(surface.cell(x: column - 1, y: 0) == Cell(style: style))
    #expect(surface.cell(x: column, y: 0)?.glyph.scalar == "x")
    #expect(surface.cell(x: column + 1, y: 0)?.glyph.scalar == "x")
    #expect(surface.cell(x: column + 2, y: 0) == Cell(style: style))
    let remainingColumn = column == 1 ? 4 : 0
    #expect(surface.cell(x: remainingColumn, y: 0)?.glyph == Glyph("漢"))
    #expect(surface.cell(x: remainingColumn + 1, y: 0)?.isContinuation == true)
  }
}

@Test func positionLayoutFailurePreservesTheLastFrameAndAllowsStorageReuse() throws {
  let drawing = PositionDrawing { $0.text("keep", in: $0.area) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 1))
  let initialBudget = surface.storageBudgetBytes
  try surface.render(size: surface.maximumSize) {
    Overlay { Canvas(drawing).position(column: 0, row: 0) }
  }
  #expect(throws: SurfaceError.layout(.textTooLong)) {
    try surface.render(size: surface.maximumSize) {
      Overlay {
        Canvas(drawing).position(column: 0, row: 0)
        Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
      }
    }
  }
  #expect(drawing.calls == 1)
  #expect(positionRow(surface, y: 0) == "keep")
  let budget = surface.storageBudgetBytes
  #expect(budget == initialBudget)
  try surface.render(size: surface.maximumSize) {
    Overlay { Text("next").position(column: 65_535, row: 65_535) }
  }
  #expect(positionRow(surface, y: 0) == "next")
  #expect(surface.storageBudgetBytes == budget)
  try surface.render(size: surface.maximumSize) {
    Overlay { PositionEmptyChildren().position(column: 65_535, row: 65_535) }
  }
  #expect(positionRow(surface, y: 0) == "    ")
  #expect(surface.storageBudgetBytes == budget)
}

private struct PositionEmptyChildren: Block {
  var body: some Block {}
}

private struct PositionMultipleChildren: Block {
  var body: some Block {
    Text("ABCD\nEFGH")
    Text("x")
  }
}

private final class PositionDrawing: CanvasDrawing {
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

private func positionRow(_ surface: borrowing Surface, y: Int) -> String {
  String((0..<surface.size.columns).map { Character(surface.cell(x: $0, y: y)!.glyph.scalar) })
}
