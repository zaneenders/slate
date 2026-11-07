import AllocationProbe
import SlateUI

func runSurfaceAllocations() throws {
  var fixture = try SurfaceFixture()
  try fixture.exercise()
  cli_probe_begin()
  do {
    for _ in 0..<10 { try fixture.exercise() }
  } catch {
    _ = cli_probe_end()
    throw error
  }
  let allocations = cli_probe_end()
  print("UI surface, borrowed cells, maximum load, exhaustion and host clipboard: \(allocations) allocations")
  precondition(allocations == 0)
}

private struct SurfaceFixture: ~Copyable {
  private var surface: Surface
  private var clipboard = Clipboard()
  private let text = String(repeating: "x", count: LayoutLimits.maximumTextScalars)
  private let oversized = String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1)
  private let copied = String(repeating: "x", count: Clipboard.maximumTextBytes)
  private let copyOverflow = String(repeating: "x", count: Clipboard.maximumTextBytes + 1)
  private let blocks: [Text]

  init() throws {
    surface = try Surface(maximumSize: TerminalSize(columns: Surface.maximumColumns, rows: Surface.maximumRows))
    blocks = Array(repeating: Text(text), count: LayoutLimits.maximumNodes)
  }

  mutating func exercise() throws {
    let size = surface.maximumSize
    let budget = surface.storageBudgetBytes
    try surface.render(size: size) { frame in frame.fill(frame.area, with: Cell(Glyph("x")!)) }
    do {
      let cells = surface.renderedCells()
      precondition(cells.count == size.columns * size.rows)
      precondition(cells[cells.count - 1].glyph.scalar == "x")
    }
    try surface.render(size: size) { BlockList(blocks.dropLast()) }
    do throws(SurfaceError) {
      try surface.render(size: size) { BlockList(blocks[...]) }
      preconditionFailure("UI surface accepted excessive nodes")
    } catch { precondition(error == .layout(.nodeCapacityExceeded)) }
    do throws(SurfaceError) {
      try surface.render(size: size) { Text(oversized) }
      preconditionFailure("UI surface accepted excessive text")
    } catch { precondition(error == .layout(.textTooLong)) }
    do throws(SurfaceError) {
      try surface.render(size: TerminalSize(columns: size.columns + 1, rows: size.rows)) { Text(text) }
      preconditionFailure("UI surface accepted an excessive viewport")
    } catch { precondition(error == .viewportCapacityExceeded) }
    precondition(surface.cell(x: size.columns - 1, y: 0)?.glyph.scalar == "x")
    try surface.render(size: TerminalSize(columns: 0, rows: 0)) { Text("empty") }
    precondition(surface.cell(x: 0, y: 0) == nil && surface.storageBudgetBytes == budget)
    try clipboard.copy(copied.utf8Span)
    do throws(ClipboardError) {
      try clipboard.copy(copyOverflow.utf8Span)
      preconditionFailure("Host clipboard accepted excessive text")
    } catch { precondition(error == .capacityExceeded) }
    clipboard.flush { text in precondition(text.count == Clipboard.maximumTextBytes) }
  }
}
