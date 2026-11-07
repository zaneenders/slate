import CIOTestSupport
import Testing

@testable import SlateTerminal

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test func regionDrawUsesLocalLayoutAndAbsoluteOutputWithoutClearingTheTerminal() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var surface = try ScreenRegion(maximumSize: TerminalSize(columns: 2, rows: 2), nodeCapacity: 4)
  let region = Rect(x: 3, y: 2, width: 2, height: 2)
  let viewport = TerminalSize(columns: 10, rows: 8)
  let painted = try surface.draw(in: region, clippedTo: viewport, to: output) { Text("AB\nCD") }
  let expected = "\u{1b}7\u{1b}[0m\u{1b}[3;4H\u{1b}[0mAB\u{1b}[4;4HCD\u{1b}[0m\u{1b}8"
  #expect(try capture.take() == Array(expected.utf8))
  #expect(painted == FrameStatistics(changedCells: 4, outputBytes: expected.utf8.count))
  #expect(surface.paintedRegion == region)
  let repeated = try surface.draw(in: region, clippedTo: viewport, to: output) { Text("AB\nCD") }
  #expect(repeated.changedCells == 4)  // A layer can be invalidated by another writer.
  #expect(try capture.take() == Array(expected.utf8))
  let cleared = try surface.clear(clippedTo: viewport, to: output)
  let erased = "\u{1b}7\u{1b}[0m\u{1b}[3;4H  \u{1b}[4;4H  \u{1b}[0m\u{1b}8"
  #expect(try capture.take() == Array(erased.utf8))
  #expect(cleared == FrameStatistics(changedCells: 4, outputBytes: erased.utf8.count))
  #expect(surface.paintedRegion == nil)
  #expect(try surface.clear(clippedTo: viewport, to: output).outputBytes == 0)
  #expect(try capture.take().isEmpty)
}

@Test func regionClipsCellsWithoutChangingLayoutAndClearsThePreviousOrigin() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var surface = try ScreenRegion(maximumSize: TerminalSize(columns: 4, rows: 2), nodeCapacity: 4)
  let viewport = TerminalSize(columns: 5, rows: 3)
  let region = Rect(x: 3, y: 2, width: 4, height: 2)
  let painted = try surface.draw(in: region, clippedTo: viewport, to: output) {
    Text("ABCD\nEFGH").frame(width: .fill, alignment: .topLeading)
  }
  #expect(painted.changedCells == 2)
  #expect(try capture.take() == Array("\u{1b}7\u{1b}[0m\u{1b}[3;4H\u{1b}[0mAB\u{1b}[0m\u{1b}8".utf8))
  #expect(surface.paintedRegion == Rect(x: 3, y: 2, width: 2, height: 1))
  let moved = try surface.draw(in: Rect(x: 1, y: 1, width: 1, height: 1), clippedTo: viewport, to: output) {
    Text("Z", style: Style(background: .blue))
  }
  #expect(moved.changedCells == 3)
  let expected =
    "\u{1b}7\u{1b}[0m\u{1b}[3;4H  \u{1b}[0m\u{1b}8"
    + "\u{1b}7\u{1b}[0m\u{1b}[2;2H\u{1b}[0;48;5;4mZ\u{1b}[0m\u{1b}8"
  #expect(try capture.take() == Array(expected.utf8))
  #expect(moved.outputBytes == expected.utf8.count)
  // Fully clipped and empty draws release the old layer without writing out of bounds.
  #expect(
    try surface.draw(in: region, clippedTo: TerminalSize(columns: 1, rows: 1), to: output) { Text("hidden") }
      .outputBytes == 0)
  #expect(surface.paintedRegion == nil)
  #expect(try capture.take().isEmpty)
  try surface.draw(
    in: Rect(x: 65_534, y: 65_534, width: 1, height: 1),
    clippedTo: TerminalSize(columns: 65_535, rows: 65_535), to: output
  ) { Text("X") }
  #expect(try capture.take() == Array("\u{1b}7\u{1b}[0m\u{1b}[65535;65535H\u{1b}[0mX\u{1b}[0m\u{1b}8".utf8))
  try surface.draw(in: Rect(width: 0, height: 0), clippedTo: viewport, to: output) { Text("empty") }
  #expect(surface.paintedRegion == nil)
  #expect(try capture.take().isEmpty)
}

@Test func regionRejectsCapacityAndLayoutExhaustionBeforeChangingTheOwnedLayer() throws {
  for size in [
    TerminalSize(columns: 0, rows: 1), TerminalSize(columns: 513, rows: 1),
    TerminalSize(columns: 1, rows: 257)
  ] {
    #expect(throws: ScreenError.invalidCapacity) {
      let invalid = try ScreenRegion(maximumSize: size)
      _ = consume invalid
    }
  }
  for capacity in [0, 513] {
    #expect(throws: ScreenError.invalidCapacity) {
      let invalid = try ScreenRegion(maximumSize: TerminalSize(columns: 1, rows: 1), nodeCapacity: capacity)
      _ = consume invalid
    }
  }
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var surface = try ScreenRegion(maximumSize: TerminalSize(columns: 2, rows: 1), nodeCapacity: 2)
  let region = Rect(x: 1, y: 1, width: 2, height: 1)
  let viewport = TerminalSize(columns: 5, rows: 5)
  try surface.draw(in: region, clippedTo: viewport, to: output) { Text("ok") }
  _ = try capture.take()
  #expect(throws: ScreenError.viewportCapacityExceeded) {
    try surface.draw(in: Rect(width: 3, height: 1), clippedTo: viewport, to: output) { Text("bad") }
  }
  #expect(throws: ScreenError.layout(.nodeCapacityExceeded)) {
    try surface.draw(in: Rect(width: 1, height: 1), clippedTo: viewport, to: output) { Column { Text("bad") } }
  }
  #expect(surface.paintedRegion == region)
  #expect(try capture.take().isEmpty)
  try surface.clear(clippedTo: viewport, to: output)
  #expect(try capture.take() == Array("\u{1b}7\u{1b}[0m\u{1b}[2;2H  \u{1b}[0m\u{1b}8".utf8))
  try surface.draw(in: region, clippedTo: viewport, to: output) { Text("ok") }
  #expect(surface.paintedRegion == region)
}

#if os(Linux)
@Test func regionRetainsOnlyOneRepairRectangleAcrossFailedMovesAndClears() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var surface = try ScreenRegion(maximumSize: TerminalSize(columns: 2, rows: 1), nodeCapacity: 2)
  let viewport = TerminalSize(columns: 20, rows: 10)
  let previous = Rect(x: 1, y: 1, width: 2, height: 1)
  let next = Rect(x: 7, y: 5, width: 2, height: 1)
  try surface.draw(in: previous, clippedTo: viewport, to: output) { Text("AB") }
  _ = try capture.take()
  defer { cli_test_reset_io() }
  // Clear succeeds; the new paint fails after five bytes.
  let steps: InlineArray<3, Int32> = [4096, 5, -EAGAIN]
  steps.span.withUnsafeBufferPointer { unsafe cli_test_write_script($0.baseAddress, $0.count) }
  #expect(throws: ScreenError.output(.write(errno: EAGAIN, bytesWritten: 5))) {
    try surface.draw(in: next, clippedTo: viewport, to: output) { Text("CD") }
  }
  #expect(surface.paintedRegion == next)
  _ = try capture.take()
  let clearSteps: InlineArray<2, Int32> = [3, -EAGAIN]
  clearSteps.span.withUnsafeBufferPointer { unsafe cli_test_write_script($0.baseAddress, $0.count) }
  #expect(throws: ScreenError.output(.write(errno: EAGAIN, bytesWritten: 3))) {
    try surface.clear(clippedTo: viewport, to: output)
  }
  #expect(surface.paintedRegion == next)
  _ = try capture.take()
  try surface.clear(clippedTo: viewport, to: output)
  #expect(surface.paintedRegion == nil)
  #expect(try capture.take() == Array("\u{1b}7\u{1b}[0m\u{1b}[6;8H  \u{1b}[0m\u{1b}8".utf8))
  try surface.draw(in: previous, clippedTo: viewport, to: output) { Text("AB") }
  #expect(surface.paintedRegion == previous)
}
#endif
