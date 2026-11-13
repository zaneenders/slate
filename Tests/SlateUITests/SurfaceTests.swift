import SlateUI
import Testing

@Test func surfaceRendersBlocksAndProvidesBorrowedCellsWithoutTerminalIO() throws {
  let size = TerminalSize(columns: 8, rows: 4)
  var surface = try Surface(maximumSize: size)
  #expect(surface.size == TerminalSize(columns: 0, rows: 0))
  #expect(surface.cell(x: 0, y: 0) == nil)
  try surface.render(size: size) {
    Column {
      Text("first")
      Text("second", style: Style(foreground: .cyan))
    }
    .border("UI").background(.blue)
  }
  do {
    let cells = surface.renderedCells()
    #expect(surface.size == size)
    #expect(cells.count == 32)
    #expect(cells[0].glyph.scalar == "┌")
    #expect(cells[9].glyph.scalar == "f")
    #expect(cells[17].glyph.scalar == "s")
    #expect(cells[17].style.foreground == .cyan)
    #expect(cells[17].style.background == .blue)
  }
  try surface.render(size: size) { Text("x") }
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "x")
  #expect(surface.cell(x: 1, y: 1) == Cell())
  #expect(surface.cell(x: 8, y: 0) == nil)
}

@Test func surfaceRejectsCapacityAndLayoutFailuresAtomicallyAndReleasesInputs() throws {
  for size in [TerminalSize(columns: 0, rows: 1), TerminalSize(columns: 513, rows: 1)] {
    #expect(throws: SurfaceError.invalidCapacity) { _ = try Surface(maximumSize: size) }
  }
  let size = TerminalSize(columns: 4, rows: 2)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { Text("keep") }
  #expect(throws: SurfaceError.viewportCapacityExceeded) {
    try surface.render(size: TerminalSize(columns: 5, rows: 1)) { Text("oversized") }
  }
  let oversized = String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1)
  #expect(throws: SurfaceError.layout(.textTooLong)) { try surface.render(size: size) { Text(oversized) } }
  weak var retained: TextInput?
  do {
    let input = try TextInput("field")
    retained = input
    #expect(throws: SurfaceError.layout(.textTooLong)) {
      try surface.render(size: size) {
        Column {
          InputBox(input)
          Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
        }
      }
    }
  }
  #expect(retained == nil)
  #expect(surface.size == size)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "k")
  try surface.render(size: size) { Text("reuse") }
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "r")
}

@Test func surfaceReusesMaximumStorageForImperativeAndEmptyFrames() throws {
  let maximum = TerminalSize(columns: Surface.maximumColumns, rows: Surface.maximumRows)
  var surface = try Surface(maximumSize: maximum)
  let budget = surface.storageBudgetBytes
  try surface.render(size: maximum) { frame in
    frame.fill(frame.area, with: Cell(Glyph("x")!, style: Style(background: .green)))
  }
  #expect(surface.cell(x: maximum.columns - 1, y: maximum.rows - 1)?.glyph.scalar == "x")
  for empty in [TerminalSize(columns: 0, rows: 0), TerminalSize(columns: 0, rows: 1)] {
    try surface.render(size: empty) { Text("empty") }
    #expect(surface.size == empty)
    #expect(surface.cell(x: 0, y: 0) == nil)
  }
  try surface.render(size: maximum) { Text("back") }
  #expect(surface.cell(x: maximum.columns - 1, y: maximum.rows - 1) == Cell())
  #expect(surface.storageBudgetBytes == budget)
}
