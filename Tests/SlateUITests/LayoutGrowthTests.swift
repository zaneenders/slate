import SlateUI
import Testing

@Test func layoutGrowsPast512NodesAndRetainsStorageAfterSmallerFrames() throws {
  let size = TerminalSize(columns: 1, rows: 1)
  var surface = try Surface(maximumSize: size)
  let blocks = Array(repeating: Text("x"), count: 4_096)
  let initialBudget = surface.storageBudgetBytes
  #expect(surface.nodeCapacity == 64)
  // The internal root occupies one slot. BlockList does not add a node.
  for (count, capacity) in [
    (63, 64), (64, 128), (127, 128), (128, 256), (255, 256), (256, 512),
    (511, 512), (512, 1_024), (1_023, 1_024), (1_024, 2_048), (4_096, 8_192)
  ] {
    try surface.render(size: size) { BlockList(blocks.prefix(count)) }
    #expect(surface.nodeCapacity == capacity)
    #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "x")
    let budget = surface.storageBudgetBytes
    try surface.render(size: size) { Text("y") }
    #expect(surface.nodeCapacity == capacity)
    #expect(surface.storageBudgetBytes == budget)
    #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "y")
  }
  let budget = surface.storageBudgetBytes
  #expect(budget > initialBudget)
  try surface.render(size: size) { BlockList(blocks[...]) }
  #expect(surface.storageBudgetBytes == budget)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "x")
}

@Test func layoutSupportsMoreThan65536DrawingsWithoutTruncatingIndices() throws {
  let size = TerminalSize(columns: 1, rows: 1)
  var surface = try Surface(maximumSize: size)
  let first = GrowthDrawing("x")
  let last = GrowthDrawing("z")
  let blocks = Array(repeating: Canvas(first), count: 65_536)
  try surface.render(size: size) {
    Overlay {
      BlockList(blocks[...])
      Canvas(last)
    }
  }
  #expect(first.calls == blocks.count)
  #expect(last.calls == 1)
  #expect(surface.nodeCapacity > 65_536)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "z")
  let budget = surface.storageBudgetBytes
  try surface.render(size: size) { Text("r") }
  #expect(surface.storageBudgetBytes == budget)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "r")
}

@Test func growingLayoutReleasesDrawingOwnersAfterPartialFailure() throws {
  let size = TerminalSize(columns: 1, rows: 1)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { Text("k") }
  weak var retained: GrowthDrawing?
  do {
    let drawing = GrowthDrawing("x")
    retained = drawing
    let blocks = Array(repeating: Canvas(drawing), count: 1_024)
    #expect(throws: SurfaceError.layout(.textTooLong)) {
      try surface.render(size: size) {
        BlockList(blocks[...])
        Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
      }
    }
    #expect(drawing.calls == 0)
  }
  #expect(retained == nil)
  #expect(surface.nodeCapacity > 1_024)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "k")
  let budget = surface.storageBudgetBytes
  try surface.render(size: size) { Text("r") }
  #expect(surface.storageBudgetBytes == budget)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "r")
}

private final class GrowthDrawing: CanvasDrawing {
  private let glyph: Glyph
  private(set) var calls = 0
  init(_ scalar: Unicode.Scalar) { glyph = Glyph(scalar)! }
  func paint(in frame: inout Frame) {
    calls += 1
    frame[0, 0] = Cell(glyph)
  }
}
