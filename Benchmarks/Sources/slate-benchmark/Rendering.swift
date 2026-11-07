import AllocationProbe
import Glibc
import SlateTerminal

func runRenderingAllocations() throws {
  var fixture = try RenderingFixture()
  cli_probe_begin()
  do { try fixture.firstFrame() } catch {
    _ = cli_probe_end()
    throw error
  }
  let firstFrame = cli_probe_end()
  precondition(firstFrame == 0, "First low-level frame allocated")
  cli_probe_begin()
  do { try fixture.regular(iteration: 0) } catch {
    _ = cli_probe_end()
    throw error
  }
  let first = cli_probe_end()

  cli_probe_begin()
  do {
    for iteration in 0..<1_000 { try fixture.regular(iteration: iteration) }
  } catch {
    _ = cli_probe_end()
    throw error
  }
  let regular = cli_probe_end()

  cli_probe_begin()
  do {
    try fixture.maximumAndExhaustion()
  } catch {
    _ = cli_probe_end()
    throw error
  }
  let coldMaximum = cli_probe_end()
  cli_probe_begin()
  do {
    for _ in 0..<10 { try fixture.maximumAndExhaustion() }
  } catch {
    _ = cli_probe_end()
    throw error
  }
  let maximum = cli_probe_end()
  print("Rendering first low-level frame: \(firstFrame) allocations")
  print("Rendering cold layout exercise: \(first) allocations (runtime initialization)")
  print("Rendering 1,000 exercises at 80x24: \(regular) allocations")
  print("Rendering cold maximum/exhaustion exercise: \(coldMaximum) allocations (runtime initialization)")
  print("Rendering 10 maximum-load/exhaustion exercises: \(maximum) allocations")
  print("Rendering storage: cell \(MemoryLayout<Cell>.stride) bytes, maximum owner budget \(fixture.budgetBytes) bytes")
  precondition(regular == 0, "Steady rendering allocated")
  precondition(maximum == 0, "Maximum-load or exhaustion rendering allocated")
}

private enum RenderingBenchmarkError: Error { case system(Int32) }

private struct RenderingFixture: ~Copyable {
  var screen: Screen
  let output: Output
  let badOutput: Output
  let maximumText: String
  let oversizedText: String
  var budgetBytes: Int { screen.storageBudgetBytes }

  init() throws {
    let descriptor = unsafe open("/dev/null", O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { throw RenderingBenchmarkError.system(errno) }
    defer { _ = close(descriptor) }
    let readOnly = unsafe open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard readOnly >= 0 else { throw RenderingBenchmarkError.system(errno) }
    defer { _ = close(readOnly) }
    let output = try Output(fileDescriptor: descriptor)
    let badOutput = try Output(fileDescriptor: readOnly)
    let screen = try Screen(maximumSize: TerminalSize(columns: Screen.maximumColumns, rows: Screen.maximumRows))
    self.output = consume output
    self.badOutput = consume badOutput
    self.screen = consume screen
    self.maximumText = String(repeating: "x", count: LayoutLimits.maximumTextScalars)
    self.oversizedText = String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1)
  }

  mutating func regular(iteration: Int) throws {
    let selected = iteration.isMultiple(of: 2)
    try screen.draw(size: TerminalSize(columns: 80, rows: 24), to: output) {
      Column(gap: 1) {
        Text("Header", style: Style(foreground: .cyan, bold: true))
        Row(gap: 1) {
          Text(selected ? "one" : "two").padding(1).border("Navigation").frame(width: .fixed(20), height: .fill)
          Column {
            if selected { Text("Selected") } else { Text("Other") }
            Text("A bounded terminal interface.").frame(width: .fill, alignment: .trailing)
          }
          .border("Content").frame(width: .fill, height: .fill)
        }
        .frame(width: .fill, height: .fill)
      }
      .padding(1).frame(width: .fill, height: .fill)
    }
    precondition(screen.cell(x: 1, y: 1)?.glyph.scalar == "H")
  }

  mutating func firstFrame() throws {
    try screen.draw(size: TerminalSize(columns: 2, rows: 2), to: output) { frame in
      frame.fill(frame.area, with: Cell(Glyph("x")!, style: Style(foreground: .cyan)))
    }
  }

  mutating func maximumAndExhaustion() throws {
    let size = screen.maximumSize
    let full = try screen.draw(size: size, to: output) { frame in
      frame.fill(frame.area, with: Cell(Glyph("x")!, style: Style(foreground: .cyan, background: .blue, bold: true)))
    }
    precondition(full.changedCells == size.columns * size.rows)
    let unchanged = try screen.draw(size: size, to: output) { frame in
      frame.fill(frame.area, with: Cell(Glyph("x")!, style: Style(foreground: .cyan, background: .blue, bold: true)))
    }
    precondition(unchanged.outputBytes == 0)
    try screen.draw(size: size, to: output) { ManyText(count: LayoutLimits.maximumNodes - 1, text: maximumText) }
    precondition(screen.cell(x: size.columns - 1, y: 0)?.glyph.scalar == "x")
    try screen.draw(size: size, to: output) { DeepLayout(depth: LayoutLimits.maximumDepth) }
    do throws(ScreenError) {
      try screen.draw(size: size, to: output) { ManyText(count: LayoutLimits.maximumNodes, text: "x") }
      preconditionFailure("Expected node exhaustion")
    } catch { precondition(error == .layout(.nodeCapacityExceeded)) }
    do throws(ScreenError) {
      try screen.draw(size: size, to: output) { DeepLayout(depth: LayoutLimits.maximumDepth + 1) }
      preconditionFailure("Expected depth exhaustion")
    } catch { precondition(error == .layout(.depthExceeded)) }
    do throws(ScreenError) {
      try screen.draw(size: size, to: output) { Text(oversizedText) }
      preconditionFailure("Expected text exhaustion")
    } catch { precondition(error == .layout(.textTooLong)) }
    do throws(ScreenError) {
      try screen.draw(size: TerminalSize(columns: size.columns + 1, rows: size.rows), to: output) { Text("x") }
      preconditionFailure("Expected viewport exhaustion")
    } catch { precondition(error == .viewportCapacityExceeded) }
    do throws(ScreenError) {
      try screen.draw(size: TerminalSize(columns: 1, rows: 1), to: badOutput) { Text("x") }
      preconditionFailure("Expected output failure")
    } catch { precondition(error == .output(.write(errno: EBADF, bytesWritten: 0))) }
    // A failed frame must be recoverable without growing or allocating storage.
    try screen.draw(size: TerminalSize(columns: 1, rows: 1), to: output) { Text("x") }
  }
}

private struct ManyText: Block {
  typealias Body = Never
  let count: Int
  let text: String
  borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    for _ in 0..<count { try Text(text)._build(into: &builder) }
  }
}

private struct DeepLayout: Block {
  typealias Body = Never
  let depth: Int
  borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let remaining = depth - 1
    if depth > 0 {
      try Column { DeepLayout(depth: remaining) }._build(into: &builder)
    } else {
      try Text("end")._build(into: &builder)
    }
  }
}
