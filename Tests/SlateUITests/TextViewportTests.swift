import SlateUI
import Testing

@Test func textViewportDisplaysBufferLinesTabsStylesAndClippedAreas() throws {
  var document = try DocumentBuffer("skip\r\nA\tBC\ré\nlast\n")
  var viewport = try TextViewport(maximumSize: TerminalSize(columns: 8, rows: 4))
  let style = Style(foreground: .cyan, background: .blue)
  try viewport.prepare(
    from: &document, firstLine: 1, firstColumn: 2,
    size: TerminalSize(columns: 4, rows: 4), style: style)
  #expect(viewportRow(viewport, row: 0) == "  BC")
  #expect(viewportRow(viewport, row: 1) == "    ")
  #expect(viewportRow(viewport, row: 2) == "st  ")
  #expect(viewportRow(viewport, row: 3) == "    ")
  #expect(viewport.cell(x: 2, y: 0)?.style == style)
  #expect(viewport.cell(x: -1, y: 0) == nil)
  #expect(viewport.cell(x: 4, y: 0) == nil)
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 3))
  try surface.render(size: surface.maximumSize) { frame in
    viewport.paint(in: Rect(x: 1, y: 1, width: 3, height: 1), frame: &frame)
  }
  #expect(surface.cell(x: 0, y: 1) == Cell())
  #expect(surface.cell(x: 3, y: 1)?.glyph.scalar == "B")
  #expect(surface.cell(x: 3, y: 1)?.style == style)
  #expect(surface.cell(x: 1, y: 2) == Cell())
}

@Test func textViewportDecodesScalarsSplitAcrossEveryShortReadAndSanitizesControls() throws {
  let bytes = Array("Aé漢😀\tZ\0\u{1b}".utf8)
  for chunkSize in 1...7 {
    var source = ViewportTestSource(bytes: bytes, chunkSize: chunkSize)
    var viewport = try TextViewport(maximumSize: TerminalSize(columns: 12, rows: 1))
    try viewport.prepare(from: &source, size: viewport.maximumSize)
    #expect(viewportRow(viewport, row: 0) == "Aé漢 😀   Z?? ")
    #expect(viewport.cell(x: 3, y: 0)?.isContinuation == true)
    #expect(viewport.cell(x: 5, y: 0)?.isContinuation == true)
    let reads = source.reads
    var surface = try Surface(maximumSize: viewport.maximumSize)
    try surface.render(size: surface.maximumSize) { frame in viewport.paint(in: frame.area, frame: &frame) }
    #expect(source.reads == reads)
    #expect(viewport.lastReadByteCount == bytes.count)
  }
}

@Test func textViewportRejectsMalformedUTF8AndSourceErrorsAtomically() throws {
  var viewport = try TextViewport(maximumSize: TerminalSize(columns: 8, rows: 1))
  var good = try DocumentBuffer("previous")
  try viewport.prepare(from: &good, size: viewport.maximumSize)
  for bytes: [UInt8] in [
    [0x80], [0xc0, 0xaf], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80],
    [0xf4, 0x90, 0x80, 0x80], [0xf0, 0x9f]
  ] {
    var invalid = ViewportTestSource(bytes: bytes, chunkSize: 1)
    #expect(throws: TextViewportError<ViewportReadFailure>.invalidUTF8(byteOffset: 0)) {
      try viewport.prepare(from: &invalid, size: viewport.maximumSize)
    }
    #expect(viewportRow(viewport, row: 0) == "previous")
  }
  var failed = ViewportTestSource(bytes: Array("hello".utf8), chunkSize: 1, failAtOffset: 2)
  #expect(throws: TextViewportError<ViewportReadFailure>.source(.failed)) {
    try viewport.prepare(from: &failed, size: viewport.maximumSize)
  }
  #expect(viewportRow(viewport, row: 0) == "previous")
  var changed = ViewportTestSource(bytes: Array("hello".utf8), chunkSize: 4, failValidationCall: 2)
  #expect(throws: TextViewportError<ViewportReadFailure>.source(.changed)) {
    try viewport.prepare(from: &changed, size: viewport.maximumSize)
  }
  #expect(viewportRow(viewport, row: 0) == "previous")
  var noProgress = ViewportTestSource(bytes: [0x78], chunkSize: 0)
  #expect(throws: TextViewportError<ViewportReadFailure>.invalidSource) {
    try viewport.prepare(from: &noProgress, size: viewport.maximumSize)
  }
}

@Test func textViewportBoundsReadWorkAndSkipsLongClippedTails() throws {
  var source = ViewportTestSource(bytes: Array(repeating: 0x78, count: 1_048_576), chunkSize: 4_096)
  var viewport = try TextViewport(maximumSize: TerminalSize(columns: 8, rows: 1), maximumReadBytes: 32)
  let budget = viewport.storageBudgetBytes
  try viewport.prepare(from: &source, size: viewport.maximumSize)
  #expect(viewportRow(viewport, row: 0) == "xxxxxxxx")
  #expect(viewport.lastReadByteCount == 32 && source.reads == 1)
  #expect(throws: TextViewportError<ViewportReadFailure>.readBudgetExceeded) {
    try viewport.prepare(from: &source, firstColumn: 1_000, size: viewport.maximumSize)
  }
  #expect(viewport.firstColumn == 0 && viewport.lastReadByteCount == 32)
  #expect(viewport.storageBudgetBytes == budget)
  #expect(viewportRow(viewport, row: 0) == "xxxxxxxx")
  try viewport.prepare(from: &source, size: TerminalSize(columns: 0, rows: 0))
  #expect(viewport.size == TerminalSize(columns: 0, rows: 0) && viewport.lastReadByteCount == 0)
}

@Test func textViewportValidatesCapacitiesAndSourceRangesBeforeCommitting() throws {
  for size in [
    TerminalSize(columns: 0, rows: 1), TerminalSize(columns: 513, rows: 1),
    TerminalSize(columns: 1, rows: 257)
  ] {
    #expect(throws: TextViewportError<Never>.invalidCapacity) { _ = try TextViewport(maximumSize: size) }
  }
  #expect(throws: TextViewportError<Never>.invalidCapacity) { _ = try TextViewport(maximumReadBytes: 0) }
  #expect(throws: TextViewportError<Never>.invalidCapacity) { _ = try TextViewport(tabWidth: 17) }
  var viewport = try TextViewport(maximumSize: TerminalSize(columns: 2, rows: 1))
  var source = ViewportTestSource(bytes: [0x78], chunkSize: 1)
  #expect(throws: TextViewportError<ViewportReadFailure>.invalidViewport) {
    try viewport.prepare(from: &source, firstLine: 1, size: viewport.maximumSize)
  }
  #expect(throws: TextViewportError<ViewportReadFailure>.invalidViewport) {
    try viewport.prepare(from: &source, size: TerminalSize(columns: 3, rows: 1))
  }
  #expect(source.reads == 0 && source.validations == 0)
  source.rangeOverride = 0..<2
  #expect(throws: TextViewportError<ViewportReadFailure>.invalidSource) {
    try viewport.prepare(from: &source, size: viewport.maximumSize)
  }
}

@Test func bufferDocumentSourceReadsRawByteRangesWithoutRequiringScalarBoundaries() throws {
  let document = try DocumentBuffer("é\r\nx")
  var output = InlineArray<1, UInt8>(repeating: 0)
  #expect(try document.readUTF8(from: 0, into: output.mutableSpan) == 1)
  #expect(output[0] == 0xc3)
  #expect(try document.readUTF8(from: 1, into: output.mutableSpan) == 1)
  #expect(output[0] == 0xa9)
  #expect(try document.lineContentRange(at: 1) == 4..<5)
  #expect(try document.readUTF8(from: 5, into: output.mutableSpan) == 0)
  #expect(throws: DocumentBufferError.invalidRange) { try document.readUTF8(from: 6, into: output.mutableSpan) }
  #expect(throws: DocumentBufferError.invalidRange) { try document.lineContentRange(at: 2) }
}

private func viewportRow(_ viewport: borrowing TextViewport, row: Int) -> String {
  var text = ""
  for column in 0..<viewport.size.columns { text.unicodeScalars.append(viewport.cell(x: column, y: row)!.glyph.scalar) }
  return text
}

private enum ViewportReadFailure: Error, Equatable { case failed, changed }

private struct ViewportTestSource: TextDocumentSource {
  var bytes: [UInt8]
  let chunkSize: Int
  var failAtOffset: Int? = nil
  var failValidationCall: Int? = nil
  var rangeOverride: Range<Int>? = nil
  var reads = 0
  var validations = 0
  var byteCount: Int { bytes.count }
  var lineCount: Int { 1 }

  mutating func validateSnapshot() throws(ViewportReadFailure) {
    validations += 1
    if validations == failValidationCall { throw .changed }
  }

  mutating func lineContentRange(at line: Int) throws(ViewportReadFailure) -> Range<Int> {
    rangeOverride ?? 0..<bytes.count
  }

  mutating func readUTF8(
    from byteOffset: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(ViewportReadFailure) -> Int {
    if let failAtOffset, byteOffset >= failAtOffset { throw .failed }
    reads += 1
    var buffer = consume buffer
    let count = min(min(buffer.count, chunkSize), bytes.count - byteOffset)
    for index in 0..<count { buffer[index] = bytes[byteOffset + index] }
    return count
  }
}
