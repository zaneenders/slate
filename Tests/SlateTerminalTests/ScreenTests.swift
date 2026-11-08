import CIOTestSupport
import SlateTestSupport
import Testing

@testable import SlateTerminal

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test func screenEmitsExactANSIAndSkipsUnchangedFrames() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: TerminalSize(columns: 2, rows: 2))
  let size = TerminalSize(columns: 2, rows: 2)
  let first = try screen.draw(size: size, to: output) { frame in
    frame.text("AB\nCD", in: frame.area)
  }
  let expected = "\u{1b}[0m\u{1b}[2J\u{1b}[1;1H\u{1b}[0mAB\u{1b}[2;1HCD\u{1b}[0m"
  #expect(try capture.take() == Array(expected.utf8))
  #expect(first.changedCells == 4 && first.outputBytes == expected.utf8.count)
  let unchanged = try screen.draw(size: size, to: output) { frame in frame.text("AB\nCD", in: frame.area) }
  #expect(unchanged == FrameStatistics(changedCells: 0, outputBytes: 0))
  #expect(try capture.take().isEmpty)
  let changed = try screen.draw(size: size, to: output) { frame in frame.text("AB\nCx", in: frame.area) }
  #expect(changed.changedCells == 1)
  #expect(try capture.take() == Array("\u{1b}[2;2H\u{1b}[0mx\u{1b}[0m".utf8))
}

@Test func screenDiffPositionsSparseChangesAndRestartsRunsAtRowBoundaries() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 4, rows: 2)
  var screen = try Screen(maximumSize: size)
  try screen.draw(size: size, to: output) { frame in frame.text("abcd\nefgh", in: frame.area) }
  _ = try capture.take()
  let cyan = Style(foreground: .cyan)
  func paint(_ frame: inout Frame) {
    frame.text("abcd\nefgh", in: frame.area)
    frame[1, 0] = Cell(Glyph("B")!, style: cyan)
    frame[2, 0] = Cell(Glyph("─")!, style: cyan)
    frame[3, 0] = Cell(Glyph("D")!, style: cyan)
    frame[0, 1] = Cell(Glyph("E")!, style: cyan)
    frame[2, 1] = Cell(Glyph("G")!, style: Style(background: .blue))
  }
  let changed = try screen.draw(size: size, to: output, render: paint)
  let expected = "\u{1b}[1;2H\u{1b}[0;38;5;6mB─D\u{1b}[2;1HE\u{1b}[2;3H\u{1b}[39;48;5;4mG\u{1b}[0m"
  #expect(try capture.take() == Array(expected.utf8))
  #expect(changed == FrameStatistics(changedCells: 5, outputBytes: expected.utf8.count))
  #expect(row(screen, y: 0, columns: 4) == "aB─D")
  #expect(row(screen, y: 1, columns: 4) == "EfGh")
  #expect(try screen.draw(size: size, to: output, render: paint).outputBytes == 0)
  #expect(try capture.take().isEmpty)
}

@Test func screenClearsRemovedTextAndRedrawsOnResizeOrInvalidation() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: TerminalSize(columns: 4, rows: 2))
  let size = TerminalSize(columns: 4, rows: 2)
  try screen.draw(size: size, to: output) { Text("long") }
  _ = try capture.take()
  #expect(try screen.draw(size: size, to: output) { Text("x") }.changedCells == 4)
  #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "x")
  #expect(screen.cell(x: 3, y: 0)?.glyph == .space)
  _ = try capture.take()
  let smaller = TerminalSize(columns: 2, rows: 1)
  #expect(try screen.draw(size: smaller, to: output) { Text("x") }.changedCells == 2)
  #expect(try capture.take().starts(with: Array("\u{1b}[0m\u{1b}[2J".utf8)))
  #expect(screen.cell(x: 2, y: 0) == nil)
  screen.invalidate()
  #expect(screen.cell(x: 0, y: 0) == nil)
  #expect(try screen.draw(size: smaller, to: output) { Text("x") }.changedCells == 2)
}

@Test func screenRejectsInvalidCapacityAndOversizedViewportsBeforeOutput() throws {
  for size in [
    TerminalSize(columns: 0, rows: 1), TerminalSize(columns: 513, rows: 1),
    TerminalSize(columns: 1, rows: 257)
  ] {
    do {
      let screen = try Screen(maximumSize: size)
      _ = consume screen
      Issue.record("Invalid capacity was accepted")
    } catch { #expect(error == .invalidCapacity) }
  }
  for capacity in [0, 513] {
    do {
      let screen = try Screen(nodeCapacity: capacity)
      _ = consume screen
      Issue.record("Invalid node capacity was accepted")
    } catch { #expect(error == .invalidCapacity) }
  }
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: TerminalSize(columns: 2, rows: 2))
  do {
    try screen.draw(size: TerminalSize(columns: 3, rows: 2), to: output) { Text("oops") }
    Issue.record("Oversized viewport was accepted")
  } catch { #expect(error == .viewportCapacityExceeded) }
  #expect(try capture.take().isEmpty)
  try screen.draw(size: TerminalSize(columns: 0, rows: 0), to: output) { Text("empty") }
  #expect(screen.cell(x: 0, y: 0) == nil)
}

@Test func layoutExhaustionPreservesLastFrameAndAllowsReuse() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: TerminalSize(columns: 4, rows: 1), nodeCapacity: 3)
  try screen.draw(size: screen.maximumSize, to: output) { Text("ok") }
  _ = try capture.take()
  do {
    try screen.draw(size: screen.maximumSize, to: output) {
      Row {
        Text("A")
        Text("B")
      }
    }
    Issue.record("Node exhaustion was accepted")
  } catch { #expect(error == .layout(.nodeCapacityExceeded)) }
  #expect(try capture.take().isEmpty)
  #expect(row(screen, y: 0, columns: 4) == "ok  ")
  #expect(try screen.draw(size: screen.maximumSize, to: output) { Text("ok") }.outputBytes == 0)
}

#if os(Linux)
@Test func partialFrameFailureInvalidatesDiffAndRepaintsOnRetry() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: TerminalSize(columns: 3, rows: 1))
  let steps: InlineArray<2, Int32> = [5, -EAGAIN]
  steps.span.withUnsafeBufferPointer { unsafe cli_test_write_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  do {
    try screen.draw(size: screen.maximumSize, to: output) { Text("abc") }
    Issue.record("Scripted output failure was ignored")
  } catch { #expect(error == .output(.write(errno: EAGAIN, bytesWritten: 5))) }
  #expect(screen.cell(x: 0, y: 0) == nil)
  #expect(try capture.take().count == 5)
  let retried = try screen.draw(size: screen.maximumSize, to: output) { Text("abc") }
  #expect(retried.changedCells == 3)
  #expect(try capture.take().starts(with: Array("\u{1b}[0m\u{1b}[2J".utf8)))
}

#endif

private func row(_ screen: borrowing Screen, y: Int, columns: Int) -> String {
  var text = ""
  for x in 0..<columns { text.unicodeScalars.append(screen.cell(x: x, y: y)!.glyph.scalar) }
  return text
}
