import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test(arguments: ["", "漢"])
func byteViewportMapsASCIIAcrossPageSeamsAndHistoryExhaustion(suffix: String) throws {
  let bytes = (0..<32_768).map { UInt8($0 % 128) } + Array(suffix.utf8)
  let fixture = try ByteFixture(bytes)
  var source = try PagedFileDocument.open(fixture.path, configuration: .init(pageBytes: 64, cachePages: 1))
  var viewport = try FileByteViewport()
  let size = TerminalSize(columns: 16, rows: 4)
  let budget = viewport.storageBudgetBytes
  var surface = try Surface(maximumSize: viewport.maximumSize)
  for offset in [0, 63, 64, 4_095, 4_096] {
    try viewport.prepare(from: &source, firstByte: offset, size: size)
    #expect(viewport.visibleRange == offset..<offset + size.columns * size.rows)
    let beforePaint = source.statistics
    try surface.render(size: size) { frame in
      viewport.paint(
        in: frame.area, frame: &frame, pageBytes: 64, previousRange: 0..<0,
        style: Style(), revealedStyle: Style(), boundaryStyle: Style())
      for index in 0..<size.columns * size.rows {
        let byteOffset = offset + index
        let byte = bytes[byteOffset]
        let expected: Unicode.Scalar = (0x20...0x7e).contains(byte) ? Unicode.Scalar(byte) : "."
        let column = index % size.columns
        let row = index / size.columns
        #expect(frame[column, row].glyph.scalar == expected)
        #expect(viewport.byteRange(column: column, row: row, clamp: false) == byteOffset..<byteOffset + 1)
      }
    }
    #expect(source.statistics == beforePaint)
  }
  // More than 128 distinct rows replaces old anchors without growing storage.
  for row in 0..<160 {
    try viewport.prepare(from: &source, firstByte: row * size.columns, size: size)
  }
  try viewport.begin(from: &source, firstByte: viewport.visibleRange.lowerBound, size: size, backwardRows: 60)
  for _ in 0..<64 {
    if !viewport.hasPendingWork { break }
    _ = try viewport.advance(from: &source)
  }
  let pending = viewport.hasPendingWork
  try #require(!pending)
  #expect(viewport.visibleRange.lowerBound == 99 * size.columns)
  try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  #expect(viewport.visibleRange == 0..<9_600)
  #expect(viewport.storageBudgetBytes == budget && source.residentPageCount == 1)
  #expect(source.statistics.evictions > 0)
}

@Test func byteViewportPreservesOffsetsAcrossUTF8ControlsAndPageSeams() throws {
  let fixture = try ByteFixture(Array("ab\r\n\t\u{1b}é漢xyz".utf8))
  var source = try PagedFileDocument.open(
    fixture.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 8))
  var viewport = try FileByteViewport(maximumSize: .init(columns: 5, rows: 3))
  try viewport.prepare(from: &source, firstByte: 1, size: viewport.maximumSize)
  #expect(viewport.visibleRange == 1..<fixture.bytes.count)
  for index in 0..<viewport.visibleRange.count { #expect(viewport.byte(at: index) == fixture.bytes[index + 1]) }
  #expect(viewport.byte(at: -1) == nil && viewport.byte(at: viewport.visibleRange.count) == nil)
  let stats = source.statistics
  var surface = try Surface(maximumSize: viewport.maximumSize)
  try surface.render(size: surface.maximumSize) { frame in
    viewport.paint(
      in: frame.area, frame: &frame, pageBytes: 4, previousRange: 0..<0,
      style: Style(), revealedStyle: Style(background: .blue), boundaryStyle: Style(foreground: .cyan))
    #expect(frame[0, 0].glyph.scalar == "b")
    #expect(frame[1, 0].glyph.scalar == ".")
    #expect(frame[3, 0].style.underlined)  // Byte four, including the control bytes.
    #expect(frame[0, 1].glyph.scalar == "é")
    #expect(frame[1, 1].glyph.scalar == "漢" && frame[2, 1].isContinuation)
    #expect(frame[3, 1].glyph.scalar == "x")
    #expect(frame[0, 2].glyph.scalar == "z")
    #expect(frame[3, 2] == Cell())
  }
  #expect(source.statistics == stats)
}

@Test func byteViewportSeeksToEndOfLongLineWithBoundedPageReplay() throws {
  let fixture = try ByteFixture(Array(repeating: 0x31, count: 1_048_576) + Array("last".utf8))
  var source = try PagedFileDocument.open(
    fixture.path, configuration: .init(pageBytes: 4_096, cachePages: 1, maximumPages: 512))
  var viewport = try FileByteViewport(maximumSize: .init(columns: 8, rows: 2))
  let budget = viewport.storageBudgetBytes + source.cacheStorageBudgetBytes
  try viewport.prepare(from: &source, firstByte: source.byteCount - 16, size: viewport.maximumSize)
  #expect(viewport.visibleRange.upperBound == source.byteCount)
  #expect(source.statistics.loads <= 3 && source.statistics.bytesRead <= 8_196)
  #expect(viewport.byte(at: 12) == 0x6c && viewport.byte(at: 15) == 0x74)
  for _ in 0..<16 {
    try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
    try viewport.prepare(from: &source, firstByte: source.byteCount - 16, size: viewport.maximumSize)
  }
  #expect(source.residentPageCount == 1)
  #expect(viewport.storageBudgetBytes + source.cacheStorageBudgetBytes == budget)
}

@Test func byteViewportMaximumGridEvictsThroughOneSlotAndRejectsOversizedRequests() throws {
  let fixture = try ByteFixture((0..<9_600).map { UInt8($0 % 256) })
  var source = try PagedFileDocument.open(
    fixture.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 2_400), content: .bytes)
  var viewport = try FileByteViewport()
  let budget = viewport.storageBudgetBytes
  try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  #expect(source.statistics.loads == 2_400 && source.statistics.evictions == 2_399)
  #expect(source.statistics.bytesRead == 9_600 && viewport.byte(at: 9_599) == 0x7f)
  let statistics = source.statistics
  var surface = try Surface(maximumSize: viewport.maximumSize)
  try surface.render(size: surface.maximumSize) { frame in
    viewport.paint(
      in: frame.area, frame: &frame, pageBytes: 4, previousRange: 0..<0,
      style: Style(), revealedStyle: Style(), boundaryStyle: Style())
    for index in 0..<9_600 {
      let byte = fixture.bytes[index]
      let scalar = (0x20...0x7e).contains(byte) ? Unicode.Scalar(byte) : "."
      #expect(frame[index % 160, index / 160].glyph.scalar == scalar)
    }
  }
  var copy = CopyBuffer()
  viewport.copy(viewport.visibleRange, to: &copy)
  copy.flush { text in
    let expected = fixture.bytes.map { (0x20...0x7e).contains($0) ? $0 : 0x2e }
    #expect(String(copying: text) == String(decoding: expected, as: UTF8.self))
  }
  #expect(source.statistics == statistics && viewport.byte(at: 0) == 0x00)
  #expect(throws: FileDocumentError.invalidRange) {
    try viewport.prepare(from: &source, firstByte: 0, size: .init(columns: 161, rows: 60))
  }
  #expect(viewport.visibleRange == 0..<9_600 && viewport.storageBudgetBytes == budget)
  #expect(throws: FileDocumentError.invalidRange) {
    try viewport.prepare(from: &source, firstByte: 9_601, size: .init(columns: 1, rows: 1))
  }
  try viewport.prepare(from: &source, firstByte: 9_600, size: .init(columns: 0, rows: 0))
  #expect(viewport.visibleRange == 9_600..<9_600)
  #expect(throws: FileDocumentError.invalidConfiguration) {
    _ = try FileByteViewport(maximumSize: .init(columns: 0, rows: 1))
  }
}

@Test func byteViewportRetainsLastPreparedBytesOnFileMutation() throws {
  let fixture = try ByteFixture(Array("previous-next".utf8))
  var source = try PagedFileDocument.open(fixture.path)
  var viewport = try FileByteViewport(maximumSize: .init(columns: 8, rows: 1))
  try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  let file = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
  try file.truncate(atOffset: 1)
  try file.close()
  #expect(throws: FileDocumentError.fileChanged) {
    try viewport.prepare(from: &source, firstByte: 8, size: .init(columns: 4, rows: 1))
  }
  #expect(viewport.visibleRange == 0..<8 && viewport.size == viewport.maximumSize)
  #expect(viewport.byte(at: 0) == 0x70 && viewport.byte(at: 7) == 0x73)
}

private struct ByteFixture: ~Copyable {
  let path: String
  let bytes: [UInt8]
  init(_ bytes: [UInt8]) throws {
    self.bytes = bytes
    path = NSTemporaryDirectory() + "slate-byte-view-" + UUID().uuidString
    try Data(bytes).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }
  deinit { try? FileManager.default.removeItem(atPath: path) }
}
