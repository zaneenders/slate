import SlateUI
import Testing

@Test func layoutUsesFixedCapacityAndPreservesTheFrameAtExhaustion() throws {
  let size = TerminalSize(columns: 1, rows: 1)
  let blocks = Array(repeating: Text("x"), count: 4_096)
  for capacity in [1, 2, 64, 128, 512, 4_096] {
    let limits = LayoutBudget(nodeCapacity: capacity)
    var surface = try Surface(maximumSize: size, layoutBudget: limits)
    let budget = surface.storageBudgetBytes
    // Root occupies one slot; BlockList consumes a visit but emits no node.
    try surface.render(size: size) { BlockList(blocks.prefix(capacity - 1)) }
    let previous = surface.cell(x: 0, y: 0)
    #expect(throws: SurfaceError.layout(.nodeCapacityExceeded)) {
      try surface.render(size: size) { BlockList(blocks.prefix(capacity)) }
    }
    #expect(surface.cell(x: 0, y: 0) == previous)
    #expect(surface.nodeCapacity == capacity)
    #expect(surface.layoutBudget == limits)
    #expect(surface.storageBudgetBytes == budget)
    try surface.render(size: size) { BlockList(blocks.prefix(min(1, capacity - 1))) }
    #expect(surface.storageBudgetBytes == budget)
  }
}

@Test func layoutSupportsMoreThan65536DrawingsWithoutTruncatingIndices() throws {
  let size = TerminalSize(columns: 1, rows: 1)
  var surface = try Surface(
    maximumSize: size, layoutBudget: .init(nodeCapacity: 65_539, maximumBlockVisits: 65_540))
  let first = BudgetDrawing("x")
  let last = BudgetDrawing("z")
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

@Test func fixedLayoutReleasesDrawingOwnersAfterPartialFailure() throws {
  let size = TerminalSize(columns: 1, rows: 1)
  var surface = try Surface(maximumSize: size, layoutBudget: .init(nodeCapacity: 16))
  try surface.render(size: size) { Text("k") }
  weak var retained: BudgetDrawing?
  do {
    let drawing = BudgetDrawing("x")
    retained = drawing
    let blocks = Array(repeating: Canvas(drawing), count: 16)
    #expect(throws: SurfaceError.layout(.nodeCapacityExceeded)) {
      try surface.render(size: size) { BlockList(blocks[...]) }
    }
    #expect(drawing.calls == 0)
  }
  #expect(retained == nil)
  #expect(surface.nodeCapacity == 16)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "k")
  let budget = surface.storageBudgetBytes
  try surface.render(size: size) { Text("r") }
  #expect(surface.storageBudgetBytes == budget)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "r")
}

@Test func layoutChargesEmptyBlocksAndResetsVisitsAfterFailure() throws {
  let size = TerminalSize(columns: 1, rows: 1)
  var surface = try Surface(maximumSize: size, layoutBudget: .init(nodeCapacity: 2, maximumBlockVisits: 7))
  let empty = Array(repeating: EmptyBudgetBlock(), count: 4)
  // BlockList + three custom blocks + their three empty bodies = seven visits.
  try surface.render(size: size) { BlockList(empty.prefix(3)) }
  try surface.render(size: size) { Text("k") }
  let budget = surface.storageBudgetBytes
  #expect(throws: SurfaceError.layout(.blockVisitLimitExceeded)) {
    try surface.render(size: size) { BlockList(empty[...]) }
  }
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "k")
  #expect(surface.storageBudgetBytes == budget)
  try surface.render(size: size) { BlockList(empty.prefix(3)) }
}

@Test func layoutRejectsRecursiveBodiesBeforeExhaustingTheCallStack() throws {
  var surface = try Surface()
  #expect(throws: SurfaceError.layout(.buildDepthExceeded)) {
    try surface.render(size: TerminalSize(columns: 1, rows: 1)) { RecursiveBudgetBlock() }
  }
}

@Test func layoutRejectsInvalidBudgetsBeforeAllocatingStorage() {
  for budget in [
    LayoutBudget(nodeCapacity: 0), LayoutBudget(nodeCapacity: -1),
    LayoutBudget(nodeCapacity: LayoutBudget.maximumNodeCapacity + 1),
    LayoutBudget(maximumBlockVisits: 0), LayoutBudget(maximumBlockVisits: -1),
    LayoutBudget(maximumBlockVisits: LayoutBudget.maximumBlockVisitsLimit + 1)
  ] {
    #expect(throws: SurfaceError.invalidCapacity) { _ = try Surface(layoutBudget: budget) }
  }
}

private struct EmptyBudgetBlock: Block { var body: some Block {} }
private struct RecursiveBudgetBlock: Block { var body: Self { self } }

private final class BudgetDrawing: CanvasDrawing {
  private let glyph: Glyph
  private(set) var calls = 0
  init(_ scalar: Unicode.Scalar) { glyph = Glyph(scalar)! }
  func paint(in frame: inout Frame) {
    calls += 1
    frame[0, 0] = Cell(glyph)
  }
}
