import AllocationProbe
import Glibc
import SlateTerminal

func runRegionAllocations() throws {
  let descriptor = unsafe open("/dev/null", O_WRONLY | O_CLOEXEC)
  precondition(descriptor >= 0)
  defer { _ = close(descriptor) }
  let readOnly = unsafe open("/dev/null", O_RDONLY | O_CLOEXEC)
  precondition(readOnly >= 0)
  defer { _ = close(readOnly) }
  let output = try Output(fileDescriptor: descriptor)
  let badOutput = try Output(fileDescriptor: readOnly)
  var fixture = try RegionFixture()
  try fixture.exercise(output: output, badOutput: badOutput)
  cli_probe_begin()
  do {
    for _ in 0..<1_000 { try fixture.exercise(output: output, badOutput: badOutput) }
  } catch {
    _ = cli_probe_end()
    throw error
  }
  let allocations = cli_probe_end()
  precondition(allocations == 0, "Region redraw/clear/move/exhaustion/recovery allocated")
  print("Region 1000 maximum-load/clipping/move/clear/exhaustion/write-failure cycles: \(allocations) allocations")
  print("Region storage: \(fixture.storageBudgetBytes) bytes")
}

private struct RegionFixture: ~Copyable {
  var surface: ScreenRegion
  let nodes = Array(repeating: Text("node"), count: 48)
  let maximumText = String(repeating: "x", count: LayoutLimits.maximumTextScalars)
  let oversizedText = String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1)
  var storageBudgetBytes: Int { surface.storageBudgetBytes }

  init() throws {
    surface = try ScreenRegion(maximumSize: TerminalSize(columns: 34, rows: 10), nodeCapacity: 48)
  }

  mutating func exercise(output: borrowing Output, badOutput: borrowing Output) throws {
    let viewport = TerminalSize(columns: 512, rows: 256)
    let region = Rect(x: 478, y: 1, width: 34, height: 10)
    let full = try surface.draw(in: region, clippedTo: viewport, to: output) {
      Text("A bounded layer").border().background(.blue)
    }
    precondition(full.changedCells == 340)
    let clipped = try surface.draw(in: region, clippedTo: TerminalSize(columns: 480, rows: 2), to: output) {
      Text("Clipped without relayout").border().background(.blue)
    }
    precondition(clipped.changedCells == 4)  // Two old cells cleared and two repainted.
    let maximumNodes = try surface.draw(in: region, clippedTo: viewport, to: output) {
      BlockList(nodes.dropLast())
    }
    precondition(maximumNodes.changedCells == 342)
    try surface.draw(in: region, clippedTo: viewport, to: output) { Text(maximumText) }
    do throws(ScreenError) {
      try surface.draw(in: region, clippedTo: viewport, to: output) { BlockList(nodes[...]) }
      preconditionFailure("Expected node exhaustion")
    } catch { precondition(error == .layout(.nodeCapacityExceeded)) }
    do throws(ScreenError) {
      try surface.draw(in: region, clippedTo: viewport, to: output) { Text(oversizedText) }
      preconditionFailure("Expected text exhaustion")
    } catch { precondition(error == .layout(.textTooLong)) }
    do throws(ScreenError) {
      try surface.draw(in: Rect(width: 35, height: 10), clippedTo: viewport, to: output) { Text("capacity") }
      preconditionFailure("Expected viewport exhaustion")
    } catch { precondition(error == .viewportCapacityExceeded) }
    do throws(ScreenError) {
      try surface.draw(in: region, clippedTo: viewport, to: badOutput) { Text("write") }
      preconditionFailure("Expected output failure")
    } catch { precondition(error == .output(.write(errno: EBADF, bytesWritten: 0))) }
    try surface.clear(clippedTo: viewport, to: output)
    precondition(surface.paintedRegion == nil)
  }
}
