import SlateUI
import Testing

@Test func canvasUsesLocalCoordinatesAndClipsDrawingInsideNestedModifiers() throws {
  let drawing = CanvasProbe { frame in
    let oversized = Rect(width: 100, height: 100)
    frame.fill(oversized, with: Cell(Glyph(".")!))
    frame.border(Rect(width: 6, height: 5))
    frame.text("abcdef", in: Rect(x: 1, y: 1, width: 6, height: 1))
    frame[frame.area.width - 1, frame.area.height - 1] = Cell(Glyph("Z")!)
  }
  var surface = try Surface(maximumSize: TerminalSize(columns: 10, rows: 7))
  try surface.render(size: surface.maximumSize) {
    Row {
      Text("L")
      Canvas(drawing).padding(1).border().frame(width: .fixed(8), height: .fixed(7))
      Text("R")
    }
  }
  #expect(drawing.area == Rect(width: 4, height: 3))
  #expect(canvasRow(surface, y: 2) == " │ ┌─── │ ")
  #expect(canvasRow(surface, y: 3) == " │ │abc │ ")
  #expect(canvasRow(surface, y: 4) == " │ │..Z │ ")
  #expect(canvasRow(surface, y: 0) == "L┌──────┐R")

  try surface.render(size: TerminalSize(columns: 6, rows: 7)) {
    Row {
      Text("L")
      Canvas(drawing).padding(1).border().frame(width: .fixed(8), height: .fixed(7))
      Text("R")
    }
  }
  #expect(drawing.area == Rect(width: 1, height: 3))
  #expect(canvasRow(surface, y: 4) == " │ Z │")
}

@Test func canvasPaintsInBlockOrderAndSkipsEmptyRegions() throws {
  let drawing = CanvasProbe { $0.fill($0.area, with: Cell(Glyph("O")!)) }
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 1))
  try surface.render(
    size: surface.maximumSize,
    content: {
      Text("base")
      Canvas(drawing).frame(width: .fixed(2), height: .fixed(1))
      Text("Z")
    },
    paint: { $0[3, 0] = Cell(Glyph("!")!) })
  #expect(canvasRow(surface, y: 0) == "ZOs!")
  #expect(drawing.calls == 1)
  try surface.render(size: TerminalSize(columns: 0, rows: 1)) { Canvas(drawing) }
  try surface.render(size: TerminalSize(columns: 4, rows: 0)) { Canvas(drawing) }
  try surface.render(size: surface.maximumSize) { Canvas(drawing).frame(width: .fixed(0)) }
  #expect(drawing.calls == 1)
}

@Test func canvasReleasesOwnersAfterSuccessAndFailureAndPreservesTheLastFrame() throws {
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 1))
  weak var released: CanvasProbe?
  do {
    let drawing = CanvasProbe { $0.text("keep", in: $0.area) }
    released = drawing
    try surface.render(size: surface.maximumSize) { Canvas(drawing) }
    #expect(drawing.calls == 1)
  }
  #expect(released == nil)
  do {
    let drawing = CanvasProbe { _ in Issue.record("Rejected layouts must not paint") }
    released = drawing
    #expect(throws: SurfaceError.layout(.textTooLong)) {
      try surface.render(size: surface.maximumSize) {
        Canvas(drawing)
        Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
      }
    }
    #expect(throws: SurfaceError.viewportCapacityExceeded) {
      try surface.render(size: TerminalSize(columns: 5, rows: 1)) { Canvas(drawing) }
    }
  }
  #expect(released == nil)
  #expect(canvasRow(surface, y: 0) == "keep")
  try surface.render(size: surface.maximumSize) { Text("next") }
  #expect(canvasRow(surface, y: 0) == "next")
}

@Test(arguments: [false, true])
func canvasRepairsWideGlyphsAcrossBothClipEdges(fill: Bool) throws {
  let style = Style(foreground: .cyan, background: .blue)
  let base = CanvasProbe { $0.text("漢漢漢", in: $0.area, style: style) }
  let drawing = CanvasProbe { frame in
    if fill {
      frame.fill(Rect(width: 100, height: 100), with: Cell(Glyph("x")!))
    } else {
      frame[0, 0] = Cell(Glyph("x")!)
      frame[1, 0] = Cell(Glyph("x")!)
    }
  }
  var surface = try Surface(maximumSize: TerminalSize(columns: 6, rows: 1))
  try surface.render(size: surface.maximumSize) {
    Canvas(base)
    Row {
      Row {}.frame(width: .fixed(1))
      Canvas(drawing).frame(width: .fixed(2))
    }
  }
  #expect(surface.cell(x: 0, y: 0) == Cell(style: style))
  #expect(surface.cell(x: 1, y: 0)?.glyph.scalar == "x")
  #expect(surface.cell(x: 2, y: 0)?.glyph.scalar == "x")
  #expect(surface.cell(x: 3, y: 0) == Cell(style: style))
  #expect(surface.cell(x: 4, y: 0)?.glyph == Glyph("漢"))
  #expect(surface.cell(x: 5, y: 0)?.isContinuation == true)
}

@Test func canvasClipsNewWideGlyphsAndRepairsCopiedContinuationCells() throws {
  let drawing = CanvasProbe { frame in
    frame[0, 0] = Cell(Glyph("漢")!)
    let continuation = frame[1, 0]
    frame[0, 0] = continuation
    #expect(frame[0, 0] == Cell() && frame[1, 0] == Cell())
    frame[frame.area.width - 1, 0] = Cell(Glyph("漢")!)
  }
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 1))
  try surface.render(size: surface.maximumSize) {
    Row {
      Text("L")
      Canvas(drawing).frame(width: .fixed(2))
      Text("R")
    }
  }
  #expect(canvasRow(surface, y: 0) == "L  R")
}

private final class CanvasProbe: CanvasDrawing {
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

private func canvasRow(_ surface: borrowing Surface, y: Int) -> String {
  String((0..<surface.size.columns).map { Character(surface.cell(x: $0, y: y)!.glyph.scalar) })
}
