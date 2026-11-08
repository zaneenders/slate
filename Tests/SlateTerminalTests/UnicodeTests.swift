import SlateTerminal
import SlateTestSupport
import Testing

@Test func unicodeANSIEncodesClustersAndRepairsWideDiffsExactly() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: .init(columns: 5, rows: 1))
  let size = screen.maximumSize
  _ = try screen.draw(size: size, to: output) { frame in frame.text("é漢😀", in: frame.area) }
  #expect(try capture.take() == Array("\u{1b}[0m\u{1b}[2J\u{1b}[1;1H\u{1b}[0mé漢😀\u{1b}[0m".utf8))
  #expect(try screen.draw(size: size, to: output) { $0.text("é漢😀", in: $0.area) }.changedCells == 0)
  #expect(try capture.take().isEmpty)
  _ = try screen.draw(size: size, to: output) { frame in frame.text("éxy😀", in: frame.area) }
  #expect(try capture.take() == Array("\u{1b}[1;2H\u{1b}[0mxy\u{1b}[0m".utf8))
  _ = try screen.draw(size: size, to: output) { frame in frame.text("ée\u{301}Z😀", in: frame.area) }
  #expect(try capture.take() == Array("\u{1b}[1;2H\u{1b}[0me\u{301}Z\u{1b}[0m".utf8))
}

@Test func unicodeTerminalModeRestoresOnExplicitAndThrowingExits() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  do {
    let mode = try output.graphemeClustering()
    #expect(try capture.take() == Array("\u{1b}[?2027s\u{1b}[?2027h".utf8))
    try mode.restore()
  }
  #expect(try capture.take() == Array("\u{1b}[?2027r".utf8))
  do {
    let mode = try output.graphemeClustering()
    try throwInsideUnicodeScope(mode)
  } catch UnicodeScopeFailure.expected {}
  #expect(try capture.take() == Array("\u{1b}[?2027s\u{1b}[?2027h\u{1b}[?2027r".utf8))
}

private enum UnicodeScopeFailure: Error { case expected }
private func throwInsideUnicodeScope(_ mode: borrowing GraphemeClustering) throws(UnicodeScopeFailure) {
  throw .expected
}
