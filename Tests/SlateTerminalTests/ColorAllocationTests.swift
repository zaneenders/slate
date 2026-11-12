#if canImport(Darwin)
import CIOTestSupport
import Darwin
import Foundation
import SlateTerminal
import Testing

/// The macOS probe script injects the counter. Setup, runtime warm-up, and test
/// diagnostics are outside the measured synchronous release-mode frame loop.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
func terminalColorAllocationAcrossEveryOutputPolicyAtMaximumSize() throws {
  try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")
  let descriptor = open("/dev/null", O_WRONLY | O_CLOEXEC)
  try #require(descriptor >= 0)
  defer { _ = close(descriptor) }
  let output = try Output(fileDescriptor: descriptor)
  let size = TerminalSize(columns: Screen.maximumColumns, rows: Screen.maximumRows)
  let drawing = AllocationColorDrawing()
  let modes: [TerminalCapabilities.ColorMode] = [.trueColor, .indexed256, .ansi16, .monochrome]
  let unicodeModes: [TerminalCapabilities.UnicodeMode] = [.grapheme, .ascii]
  for color in modes {
    for unicode in unicodeModes {
      var screen = try Screen(maximumSize: size, capabilities: .init(color: color, unicode: unicode))
      let budget = screen.storageBudgetBytes
      for phase in 0..<2 {
        drawing.phase = phase
        try screen.draw(size: size, to: output) { Canvas(drawing) }
      }
      cli_test_begin_allocation_count()
      var changed = 0
      do throws(ScreenError) {
        for phase in 0..<2 {
          drawing.phase = phase
          changed += try screen.draw(size: size, to: output) { Canvas(drawing) }.changedCells
        }
      } catch {
        _ = cli_test_end_allocation_count()
        throw error
      }
      let calls = cli_test_end_allocation_count()
      #expect(calls == 0)
      #expect(changed == size.columns * size.rows * 2)
      #expect(screen.storageBudgetBytes == budget)
    }
  }
}

private final class AllocationColorDrawing: CanvasDrawing {
  let glyph = Glyph(text: "漢")!
  var phase = 0

  func paint(in frame: inout Frame) {
    for y in 0..<frame.area.height {
      for x in stride(from: 0, to: frame.area.width, by: 2) {
        frame[x, y] = Cell(
          glyph,
          style: Style(
            foreground: .rgb(UInt8(truncatingIfNeeded: x + phase), UInt8(truncatingIfNeeded: y), 127),
            background: .rgb(20, 40, 60)))
      }
    }
  }
}
#endif
