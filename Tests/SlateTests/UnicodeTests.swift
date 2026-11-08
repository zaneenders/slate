import SlateComposition
import SlateUI
import Testing

@testable import SlateTerminal

@Test func unicodeFragmentStartStatesResumeContextAndOversizedClustersExactly() {
  struct Fragment {
    let glyph: Glyph
    let range: Range<Int>
    let recognizer: UnicodeGraphemeRecognizer
    let fragmented: Bool
  }
  func collect(
    _ text: String, offset: Int = 0,
    recognizer: UnicodeGraphemeRecognizer = .init(), fragmented: Bool = false
  ) -> [Fragment] {
    var buffer = UnicodeGraphemeBuffer(recognizer: recognizer, fragmented: fragmented)
    var result: [Fragment] = []
    var position = offset
    for scalar in text.unicodeScalars {
      let initial = buffer.initialState
      if let cluster = buffer.append(scalar, at: position) {
        result.append(
          .init(
            glyph: cluster.glyph, range: cluster.byteRange,
            recognizer: initial.recognizer, fragmented: initial.fragmented))
      }
      position += scalar.utf8Length
    }
    let initial = buffer.initialState
    if let cluster = buffer.take() {
      result.append(
        .init(
          glyph: cluster.glyph, range: cluster.byteRange,
          recognizer: initial.recognizer, fragmented: initial.fragmented))
    }
    return result
  }
  let text = "🇦🇧🇨🇩🇪각क्‍ष👩🏽‍💻" + "a" + String(repeating: "\u{301}", count: 80) + "e\u{301}Z"
  let bytes = Array(text.utf8)
  let expected = collect(text)
  for (index, fragment) in expected.enumerated() {
    let suffix = String(decoding: bytes[fragment.range.lowerBound...], as: UTF8.self)
    let actual = collect(
      suffix, offset: fragment.range.lowerBound, recognizer: fragment.recognizer, fragmented: fragment.fragmented)
    #expect(actual.map(\.range) == expected[index...].map(\.range))
    #expect(actual.map(\.glyph) == expected[index...].map(\.glyph))
  }
}

@Test func unicodeGlyphsOwnTheirUTF8AndHaveTerminalWidths() throws {
  for (text, width) in [
    ("é", 1), ("Ω", 1), ("Ж", 1), ("e\u{301}", 1), ("क्‍ष", 2),
    ("漢", 2), ("😀", 2), ("👩🏽‍💻", 2), ("🇺🇸", 2), ("1️⃣", 2), ("❤️", 2),
    ("☀︎", 1), ("☀️", 2), ("A\u{fe0f}", 1), ("⌚︎", 1), ("〰︎", 1),
    ("กำ", 2), ("ກຳ", 2), ("का", 2), ("கொ", 2), ("क्ष्म", 2), ("ক্ষ্ম", 2)
  ] {
    let glyph = try #require(Glyph(text: text))
    #expect(glyph.columnWidth == width)
    #expect(String(copying: glyph.utf8()) == text)
    #expect(glyph.byteCount == text.utf8.count)
    #expect(glyph == Glyph(text: text))
  }
  for text in ["", "ab", "\n", "\u{1b}", "\u{85}", "\u{202e}", "\u{301}", "\u{200d}"] {
    #expect(Glyph(text: text) == nil)
  }
  #expect(Glyph(text: "e" + String(repeating: "\u{301}", count: 32)) == nil)
  #expect(Glyph(text: "e\u{301}") != Glyph(text: "e\u{302}"))
  #expect(MemoryLayout<Glyph>.stride <= 80 && MemoryLayout<Cell>.stride <= 96)
  print("unicode-storage glyph_bytes=\(MemoryLayout<Glyph>.stride) cell_bytes=\(MemoryLayout<Cell>.stride)")
}

@Test func swiftStreamingGraphemesMatchCharacterBoundariesAndBoundOverflow() throws {
  for text in ["", "abc", "a\r\nb", "e\u{301}漢👩🏽‍💻🇺🇸1️⃣Z", "क्‍ष", "각"] {
    var expected: [Range<Int>] = []
    var offset = 0
    for character in text {
      let end = offset + character.utf8.count
      expected.append(offset..<end)
      offset = end
    }
    var iterator = UnicodeTextIterator(text.utf8Span)
    var actual: [Range<Int>] = []
    while let cluster = iterator.next() { actual.append(cluster.byteRange) }
    #expect(actual == expected)
    #expect(iterator.next() == nil)
  }
  let long = "e" + String(repeating: "\u{301}", count: 80) + "Z"
  var iterator = UnicodeTextIterator(long.utf8Span)
  var consumed = 0
  var replacements = 0
  while let cluster = iterator.next() {
    #expect(cluster.byteRange.lowerBound == consumed && cluster.byteRange.count <= 64)
    consumed = cluster.byteRange.upperBound
    if cluster.glyph == .replacement { replacements += 1 } else { #expect(cluster.glyph.scalar == "Z") }
  }
  #expect(consumed == long.utf8.count && replacements == 3)
}

@Test func unicodeFramePreservesWideFootprintsAndClipsBothEdges() throws {
  let size = TerminalSize(columns: 8, rows: 2)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { frame in
    frame.text("é漢e\u{301}😀", in: frame.area)
    #expect(String(copying: frame[0, 0].glyph.utf8()) == "é")
    #expect(frame[1, 0].glyph.scalar == "漢" && frame[2, 0].isContinuation)
    #expect(String(copying: frame[3, 0].glyph.utf8()) == "e\u{301}")
    #expect(frame[4, 0].glyph.scalar == "😀" && frame[5, 0].isContinuation)
    frame[2, 0] = Cell(Glyph("x")!)
    #expect(frame[1, 0].glyph == .space && frame[2, 0].glyph.scalar == "x")
    frame[4, 0] = Cell(Glyph("y")!)
    #expect(frame[5, 0].glyph == .space && !frame[5, 0].isContinuation)
    frame[6, 0] = Cell(Glyph("漢")!)
    frame[5, 0] = Cell(Glyph("漢")!)
    #expect(frame[6, 0].isContinuation && frame[7, 0].glyph == .space)
    frame.text("漢", in: Rect(x: 7, y: 1, width: 1, height: 1))
    #expect(frame[7, 1].glyph == .space)
  }
}

@Test func unicodeLayoutAndInputUseColumnsWhileEditingUsesGraphemes() throws {
  let input = try TextInput("e\u{301}漢😀")
  let size = TerminalSize(columns: 10, rows: 2)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) {
    Column {
      Row {
        Text("漢")
        Text("X")
      }
      InputBox(input)
    }
  }
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "漢")
  #expect(surface.cell(x: 1, y: 0)?.isContinuation == true)
  #expect(surface.cell(x: 2, y: 0)?.glyph.scalar == "X")
  #expect(String(copying: surface.cell(x: 0, y: 1)!.glyph.utf8()) == "e\u{301}")
  #expect(surface.cell(x: 1, y: 1)?.glyph.scalar == "漢")
  #expect(surface.cell(x: 3, y: 1)?.glyph.scalar == "😀")
  var copy = CopyBuffer()
  _ = input.handle(.left, copyBuffer: &copy)
  #expect(input.cursorByteOffset == "e\u{301}漢".utf8.count)
  _ = input.handle(.backspace, copyBuffer: &copy)
  #expect(input.snapshot() == "e\u{301}😀")
}

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
