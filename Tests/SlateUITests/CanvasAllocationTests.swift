#if canImport(Darwin)
import CIOTestSupport
import Foundation
import SlateUI
import Testing

/// Run Scripts/check-render-allocations.sh in an optimized build. The injected
/// probe counts allocation API calls, not retained heap size. A synchronous
/// measured region stays on one thread; setup, warm-up, assertions, clocks, and
/// reporting stay outside it. Expected errors have a bounded allocation exception.
/// The process-wide probe permits only one active measured region.
@Suite(.serialized)
struct RenderAllocationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func hitMapAllocationAcrossRegistrationLookupAndHiddenTargets() throws {
    try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")
    let size = TerminalSize(columns: 80, rows: 24)
    let hits = HitMap<Int>(capacity: 64)
    let blocks = (0..<64).map { Text("target").hitRegion($0, in: hits) }
    var surface = try Surface(maximumSize: size)
    for _ in 0..<4 {
      try surface.render(size: size) { BlockList(blocks[...]) }
      _ = hits.hitTest(column: 0, row: 0)
      _ = hits.bounds(for: 63)
      try surface.render(size: size) { Text("hidden") }
    }
    let budget = surface.storageBudgetBytes + hits.storageBudgetBytes
    cli_test_begin_allocation_count()
    do throws(SurfaceError) {
      for _ in 0..<32 {
        try surface.render(size: size) { BlockList(blocks[...]) }
        _ = hits.hitTest(column: 0, row: 0)
        _ = hits.bounds(for: 63)
        try surface.render(size: size) { Text("hidden") }
      }
    } catch {
      _ = cli_test_end_allocation_count()
      throw error
    }
    let calls = cli_test_end_allocation_count()
    #expect(calls == 0 && hits.count == 0)
    #expect(surface.storageBudgetBytes + hits.storageBudgetBytes == budget)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func fixedLayoutAllocationAtMaximumCapacityAndExhaustion() throws {
    try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")
    let size = TerminalSize(columns: Surface.maximumColumns, rows: Surface.maximumRows)
    let limits = LayoutBudget(
      nodeCapacity: LayoutBudget.maximumNodeCapacity,
      maximumBlockVisits: LayoutBudget.maximumBlockVisitsLimit)
    let drawing = AllocationPointDrawing()
    let blocks = Array(repeating: Canvas(drawing), count: limits.nodeCapacity)
    let fitting = blocks.prefix(limits.nodeCapacity - 1)
    var surface = try Surface(maximumSize: size, layoutBudget: limits)
    let initialBudget = surface.storageBudgetBytes
    for _ in 0..<4 { try surface.render(size: size) { BlockList(fitting) } }
    cli_test_begin_allocation_count()
    do throws(SurfaceError) {
      for _ in 0..<4 {
        try surface.render(size: size) { BlockList(blocks.prefix(1)) }
        try surface.render(size: size) { BlockList(fitting) }
      }
    } catch {
      _ = cli_test_end_allocation_count()
      throw error
    }
    let renderCalls = cli_test_end_allocation_count()
    #expect(renderCalls == 0)
    #expect(surface.nodeCapacity == limits.nodeCapacity)
    #expect(surface.storageBudgetBytes == initialBudget)
    #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "x")
    _ = rejectFixedAllocationFrame(&surface, size: size, blocks: blocks[...])
    cli_test_begin_allocation_count()
    var rejections = 0
    for _ in 0..<4 {
      if rejectFixedAllocationFrame(&surface, size: size, blocks: blocks[...]) { rejections += 1 }
    }
    let rejectionCalls = cli_test_end_allocation_count()
    #expect(rejections == 4 && rejectionCalls <= UInt64(rejections) * 2)
    #expect(surface.storageBudgetBytes == initialBudget)
    #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "x")
    print(
      "Fixed layout: \(limits.nodeCapacity) nodes, \(initialBudget) bytes; \(renderCalls) render allocations; \(rejectionCalls) rejection diagnostics"
    )
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func fixedLayoutAllocationAtVisitExhaustion() throws {
    try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")
    let size = TerminalSize(columns: 1, rows: 1)
    // Each custom block and its empty body are separate visits, plus BlockList.
    let limits = LayoutBudget(nodeCapacity: 2, maximumBlockVisits: LayoutBudget.maximumBlockVisitsLimit)
    let blocks = Array(repeating: AllocationEmptyBlock(), count: limits.maximumBlockVisits / 2)
    var surface = try Surface(maximumSize: size, layoutBudget: limits)
    try surface.render(size: size) { Text("k") }
    _ = rejectVisitAllocationFrame(&surface, size: size, blocks: blocks[...])
    cli_test_begin_allocation_count()
    let rejected = rejectVisitAllocationFrame(&surface, size: size, blocks: blocks[...])
    let calls = cli_test_end_allocation_count()
    #expect(rejected && calls <= 2)
    #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "k")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func canvasAllocationAtMaximumGridWithLargeLayoutsAndFailures() throws {
    try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")

    // Positive control: an allocating Swift buffer must be visible to the probe.
    _ = allocationControl(32)
    cli_test_begin_allocation_count()
    let control = allocationControl(32_768)
    let controlCalls = cli_test_end_allocation_count()
    #expect(control == 32_768 && controlCalls > 0)

    let size = TerminalSize(columns: Surface.maximumColumns, rows: Surface.maximumRows)
    var surface = try Surface(maximumSize: size)
    let drawing = AllocationDrawing()
    // The root and Row occupy two nodes in addition to the canvases.
    let blocks = Array(repeating: Canvas(drawing), count: 4_094)
    let fitting = blocks[...]
    let invalidText = String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1)
    for _ in 0..<4 { try renderAllocationFrame(&surface, size: size, blocks: fitting) }
    let initialBudget = surface.storageBudgetBytes
    let clock = ContinuousClock()
    let start = clock.now
    cli_test_begin_allocation_count()
    do throws(SurfaceError) {
      for _ in 0..<8 { try renderAllocationFrame(&surface, size: size, blocks: fitting) }
    } catch {
      _ = cli_test_end_allocation_count()
      throw error
    }
    let renderCalls = cli_test_end_allocation_count()
    let duration = start.duration(to: clock.now)
    print(
      "Canvas: 8 frames at \(size.columns)x\(size.rows), \(fitting.count) canvases/frame, \(duration), "
        + "\(renderCalls) allocation calls, \(initialBudget) owned bytes")
    #expect(renderCalls == 0)
    #expect(surface.storageBudgetBytes == initialBudget)
    #expect(surface.cell(x: size.columns - 1, y: size.rows - 1)?.glyph.scalar == "x")

    // Warm the error path too. Layout rejection must keep the previous frame and
    // release temporary owner references so the same storage can be reused.
    _ = rejectAllocationFrame(&surface, size: size, blocks: fitting, invalidText: invalidText)
    cli_test_begin_allocation_count()
    var rejections = 0
    for _ in 0..<8 {
      if rejectAllocationFrame(&surface, size: size, blocks: fitting, invalidText: invalidText) { rejections += 1 }
    }
    let rejectionCalls = cli_test_end_allocation_count()
    #expect(rejections == 8)
    // Swift Testing captures thrown-error backtraces at the two propagation sites.
    // Bound that diagnostic cost; successful frames must still allocate nothing.
    #expect(rejectionCalls <= UInt64(rejections) * 2)
    print("Canvas layout rejection: \(rejections) attempts, \(rejectionCalls) allocation calls")
    #expect(surface.storageBudgetBytes == initialBudget)
    #expect(surface.cell(x: size.columns - 1, y: size.rows - 1)?.glyph.scalar == "x")
    try renderAllocationFrame(&surface, size: size, blocks: fitting)

    // Overlapping layers share the grid. Each deliberately paints one
    // cell: this measures the compositor, not repeated full-grid caller drawing.
    let point = AllocationPointDrawing()
    let layers = Array(repeating: Canvas(point), count: 4_094)
    for _ in 0..<4 { try renderAllocationLayers(&surface, size: size, layers: layers[...]) }
    cli_test_begin_allocation_count()
    do throws(SurfaceError) {
      for _ in 0..<8 { try renderAllocationLayers(&surface, size: size, layers: layers[...]) }
    } catch {
      _ = cli_test_end_allocation_count()
      throw error
    }
    let layerCalls = cli_test_end_allocation_count()
    #expect(layerCalls == 0)
    #expect(surface.storageBudgetBytes == initialBudget)
    #expect(surface.cell(x: 0, y: 0)?.style.background == .rgb(20, 40, 60))
    #expect(surface.cell(x: size.columns - 1, y: size.rows - 1) == Cell())
    print("Overlay: 8 frames with \(layers.count) layers/frame, \(layerCalls) allocation calls")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func positionAllocationAtMaximumGridWithLargeLayoutsAndFailures() throws {
    try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")
    _ = allocationControl(32)
    cli_test_begin_allocation_count()
    let control = allocationControl(32_768)
    let controlCalls = cli_test_end_allocation_count()
    #expect(control == 32_768 && controlCalls > 0)

    let size = TerminalSize(columns: Surface.maximumColumns, rows: Surface.maximumRows)
    var surface = try Surface(maximumSize: size)
    let point = AllocationPointDrawing()
    let layerCount = 1_024
    let invalidText = String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1)
    // Each layer has position + frame + Canvas nodes. Prepare three sets before
    // measurement so moving layers needs no caller-owned array allocations.
    let positions = [(0, 0), (17, 9), (65_535, 65_535)]
    let layerSets = positions.map { column, row in
      Array(
        repeating: Canvas(point).frame(width: .fixed(1), height: .fixed(1)).position(column: column, row: row),
        count: layerCount)
    }
    for index in layerSets.indices {
      for _ in 0..<4 { try renderPositionAllocationLayers(&surface, size: size, layers: layerSets[index][...]) }
      let (column, row) = positions[index]
      #expect(surface.cell(x: min(column, size.columns - 1), y: min(row, size.rows - 1))?.glyph.scalar == "x")
    }
    let initialBudget = surface.storageBudgetBytes

    cli_test_begin_allocation_count()
    do throws(SurfaceError) {
      for frame in 0..<8 {
        try renderPositionAllocationLayers(&surface, size: size, layers: layerSets[frame % layerSets.count][...])
      }
    } catch {
      _ = cli_test_end_allocation_count()
      throw error
    }
    let renderCalls = cli_test_end_allocation_count()
    #expect(renderCalls == 0)
    #expect(surface.storageBudgetBytes == initialBudget)
    #expect(surface.cell(x: 17, y: 9)?.glyph.scalar == "x")
    #expect(surface.cell(x: 0, y: 0) == Cell())
    #expect(surface.cell(x: size.columns - 1, y: size.rows - 1) == Cell())
    print("Position: 8 frames with \(layerCount) moved layers/frame, \(renderCalls) allocation calls")

    for layers in layerSets {
      _ = rejectPositionAllocationLayers(&surface, size: size, layers: layers[...], invalidText: invalidText)
    }
    cli_test_begin_allocation_count()
    var rejections = 0
    for frame in 0..<8 {
      if rejectPositionAllocationLayers(
        &surface, size: size, layers: layerSets[frame % layerSets.count][...], invalidText: invalidText)
      {
        rejections += 1
      }
    }
    let rejectionCalls = cli_test_end_allocation_count()
    #expect(rejections == 8)
    // Swift Testing's two thrown-error propagation diagnostics are the only
    // permitted allocations; failed builds must preserve the previous frame.
    #expect(rejectionCalls <= UInt64(rejections) * 2)
    #expect(surface.storageBudgetBytes == initialBudget)
    #expect(surface.cell(x: 17, y: 9)?.glyph.scalar == "x")
    #expect(surface.cell(x: 0, y: 0) == Cell())
    #expect(surface.cell(x: size.columns - 1, y: size.rows - 1) == Cell())
    print("Position layout rejection: \(rejections) attempts, \(rejectionCalls) allocation calls")

    try renderPositionAllocationLayers(&surface, size: size, layers: layerSets[2][...])
    #expect(surface.cell(x: size.columns - 1, y: size.rows - 1)?.glyph.scalar == "x")
    #expect(surface.cell(x: 17, y: 9) == Cell())
    #expect(surface.storageBudgetBytes == initialBudget)
  }

}

private struct AllocationEmptyBlock: Block { var body: some Block {} }

@inline(never)
private func rejectFixedAllocationFrame(
  _ surface: inout Surface, size: TerminalSize, blocks: ArraySlice<Canvas>
) -> Bool {
  do throws(SurfaceError) {
    try surface.render(size: size) { BlockList(blocks) }
    return false
  } catch { return error == .layout(.nodeCapacityExceeded) }
}

@inline(never)
private func rejectVisitAllocationFrame(
  _ surface: inout Surface, size: TerminalSize, blocks: ArraySlice<AllocationEmptyBlock>
) -> Bool {
  do throws(SurfaceError) {
    try surface.render(size: size) { BlockList(blocks) }
    return false
  } catch { return error == .layout(.blockVisitLimitExceeded) }
}

private final class AllocationDrawing: CanvasDrawing {
  private let cell = Cell(Glyph("x")!, style: Style(foreground: .cyan))
  func paint(in frame: inout Frame) { frame.fill(frame.area, with: cell) }
}

private final class AllocationPointDrawing: CanvasDrawing {
  private let cell = Cell(Glyph("x")!, style: Style(background: .rgb(20, 40, 60)))
  func paint(in frame: inout Frame) { frame[0, 0] = cell }
}

@inline(never)
private func renderAllocationLayers(
  _ surface: inout Surface, size: TerminalSize, layers: ArraySlice<Canvas>
) throws(SurfaceError) {
  try surface.render(size: size) { Overlay { BlockList(layers) } }
}

@inline(never)
private func renderPositionAllocationLayers<Layer: Block>(
  _ surface: inout Surface, size: TerminalSize, layers: ArraySlice<Layer>
) throws(SurfaceError) {
  try surface.render(size: size) { Overlay { BlockList(layers) } }
}

@inline(never)
private func rejectPositionAllocationLayers<Layer: Block>(
  _ surface: inout Surface, size: TerminalSize, layers: ArraySlice<Layer>, invalidText: String
) -> Bool {
  do throws(SurfaceError) {
    try surface.render(size: size) {
      Overlay {
        BlockList(layers)
        Text(invalidText)
      }
    }
    return false
  } catch { return error == .layout(.textTooLong) }
}

@inline(never)
private func allocationControl(_ count: Int) -> Int {
  let bytes = Array(repeating: UInt8(1), count: count)
  return bytes.withUnsafeBufferPointer { buffer in
    // C sees the storage so the optimizer cannot remove the allocation.
    memchr(buffer.baseAddress, 1, buffer.count) == nil ? 0 : buffer.count
  }
}

@inline(never)
private func renderAllocationFrame(
  _ surface: inout Surface, size: TerminalSize, blocks: ArraySlice<Canvas>
) throws(SurfaceError) {
  try surface.render(size: size) { Row { BlockList(blocks) } }
}

@inline(never)
private func rejectAllocationFrame(
  _ surface: inout Surface, size: TerminalSize, blocks: ArraySlice<Canvas>, invalidText: String
) -> Bool {
  do throws(SurfaceError) {
    try surface.render(size: size) {
      Row {
        BlockList(blocks)
        Text(invalidText)
      }
    }
    return false
  } catch { return error == .layout(.textTooLong) }
}
#endif
