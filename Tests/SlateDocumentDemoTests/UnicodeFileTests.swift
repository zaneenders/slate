import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func unicodeFileSeeksAndMapsWholeGraphemesAcrossEveryPageSeam() throws {
  let text = "Ae\u{301}漢👩🏽‍💻🇺🇸1️⃣Z"
  let fixture = try UnicodeFileFixture(Array(text.utf8))
  var reference: [(text: String, range: Range<Int>, width: Int)] = []
  var start = 0
  for character in text {
    let value = String(character)
    let end = start + value.utf8.count
    reference.append((value, start..<end, ["A", "e\u{301}", "Z"].contains(value) ? 1 : 2))
    start = end
  }
  let size = TerminalSize(columns: 8, rows: 4)
  var surface = try Surface(maximumSize: size)
  for pageBytes in 4...13 {
    var source = try PagedFileDocument.open(
      fixture.path, configuration: .init(pageBytes: pageBytes, cachePages: 1, maximumPages: 32), content: .bytes)
    var viewport = try FileByteViewport(maximumSize: size)
    for offset in 0..<fixture.bytes.count {
      try viewport.prepare(from: &source, firstByte: offset, size: size)
      let first = try #require(reference.firstIndex { $0.range.upperBound > offset })
      #expect(viewport.visibleRange == reference[first].range.lowerBound..<fixture.bytes.count)
      for index in 0..<viewport.visibleRange.count {
        #expect(viewport.byte(at: index) == fixture.bytes[viewport.visibleRange.lowerBound + index])
      }
      let statistics = source.statistics
      try surface.render(size: size) { frame in
        viewport.paint(
          in: frame.area, frame: &frame, pageBytes: pageBytes, previousRange: 0..<0,
          style: Style(), revealedStyle: Style(), boundaryStyle: Style())
        var column = 0
        var row = 0
        for expected in reference[first...] {
          if column + expected.width > size.columns {
            column = 0
            row += 1
          }
          #expect(String(copying: frame[column, row].glyph.utf8()) == expected.text)
          #expect(viewport.byteRange(column: column, row: row, clamp: false) == expected.range)
          if expected.width == 2 {
            #expect(frame[column + 1, row].isContinuation)
            #expect(viewport.byteRange(column: column + 1, row: row, clamp: false) == expected.range)
          }
          column += expected.width
          if column == size.columns {
            column = 0
            row += 1
          }
        }
      }
      #expect(source.statistics == statistics)
    }
  }
}

@Test(arguments: ["", "漢"])
func viewportPreparationYieldsAndRetainsTheLastSnapshotOnMutation(suffix: String) throws {
  let fixture = try UnicodeFileFixture(Array((String(repeating: "a", count: 131_072) + suffix).utf8))
  var source = try PagedFileDocument.open(fixture.path, configuration: .init(pageBytes: 65_536, cachePages: 1))
  var viewport = try FileByteViewport(maximumSize: .init(columns: 8, rows: 2))
  try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  let previous = viewport.visibleRange
  let budget = viewport.storageBudgetBytes
  try viewport.begin(from: &source, firstByte: 100_000, size: viewport.maximumSize)
  #expect(viewport.hasPendingWork && viewport.visibleRange == previous)
  #expect(try !viewport.advance(from: &source, maximumScalars: 1))
  #expect(viewport.hasPendingWork && viewport.visibleRange == previous)
  #expect(throws: FileDocumentError.invalidConfiguration) { try viewport.advance(from: &source, maximumScalars: 0) }
  let beforeCancellation = source.statistics
  viewport.cancelPreparation()
  #expect(try !viewport.advance(from: &source))
  #expect(viewport.visibleRange == previous && source.statistics == beforeCancellation)
  try viewport.begin(from: &source, firstByte: 100_000, size: viewport.maximumSize)
  let file = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
  try file.truncate(atOffset: 1)
  try file.close()
  #expect(throws: FileDocumentError.fileChanged) { try viewport.advance(from: &source) }
  #expect(!viewport.hasPendingWork && viewport.visibleRange == previous)
  #expect(viewport.byte(at: 0) == 0x61 && viewport.storageBudgetBytes == budget)
}

@Test func unicodeViewerNavigatesSelectsWideCellsAndCopiesOriginalUTF8() throws {
  let text = String(repeating: "Aé漢e\u{301}😀Z", count: 512)
  let fixture = try UnicodeFileFixture(Array(text.utf8))
  let viewer = try DocumentFileViewer(
    fixture.path, configuration: .init(pageBytes: 64, cachePages: 1, maximumPages: 256))
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  viewer.prepare(in: size)
  try finishViewportPreparation(viewer)
  let budget = viewer.storageBudgetBytes
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x + 3, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: layout.text.x + 1, row: layout.text.y))
  _ = viewer.mouse(.init(action: .release, button: .left, column: layout.text.x + 1, row: layout.text.y))
  #expect(viewer.selectionRange == 1..<6)
  var copy = CopyBuffer()
  let statistics = viewer.statistics
  _ = viewer.copySelection(to: &copy)
  copy.flush { text in #expect(String(copying: text) == "é漢") }
  #expect(viewer.statistics == statistics)
  _ = viewer.handle(.down, modifiers: [])
  viewer.prepare(in: size)
  try finishViewportPreparation(viewer)
  #expect(viewer.firstByte > 0)
  _ = viewer.handle(.up, modifiers: [])
  viewer.prepare(in: size)
  try finishViewportPreparation(viewer)
  #expect(viewer.firstByte == 0)
  _ = viewer.handle(.end, modifiers: [])
  viewer.prepare(in: size)
  try finishViewportPreparation(viewer)
  #expect(viewer.visibleRange.upperBound == fixture.bytes.count && viewer.notice.isEmpty)
  let endStart = viewer.firstByte
  _ = viewer.handle(.up, modifiers: [])
  viewer.prepare(in: size)
  try finishViewportPreparation(viewer)
  #expect(viewer.firstByte < endStart && viewer.notice.isEmpty)
  #expect(viewer.storageBudgetBytes == budget)
  _ = viewer.handle(.home, modifiers: [])
  viewer.prepare(in: size)
  try finishViewportPreparation(viewer)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534))
  let tick = ContinuousClock().now.advanced(by: .seconds(1))
  for step in 0..<4 {
    _ = viewer.performPendingWork(at: tick.advanced(by: .milliseconds(step * 50)))
    viewer.prepare(in: size)
    try finishViewportPreparation(viewer)
  }
  _ = viewer.mouse(.init(action: .release, button: .left, column: 65_534, row: 65_534))
  let range = try #require(viewer.selectionRange)
  #expect(range.lowerBound == 0 && range.lowerBound < viewer.visibleRange.lowerBound)
  var boundaries: Set<Int> = [0]
  var offset = 0
  for character in text {
    offset += character.utf8.count
    boundaries.insert(offset)
  }
  #expect(boundaries.contains(range.upperBound))
  _ = viewer.copySelection(to: &copy)
  copy.flush { value in #expect(String(copying: value) == String(decoding: fixture.bytes[range], as: UTF8.self)) }
}

@Test func unicodeMaximumGridAndOversizedClustersKeepTheirStorageBound() throws {
  let cluster = "a" + String(repeating: "\u{301}", count: 31)
  let text = String(repeating: cluster, count: 9_600)
  let fixture = try UnicodeFileFixture(Array(text.utf8))
  var source = try PagedFileDocument.open(
    fixture.path, configuration: .init(pageBytes: 256, cachePages: 1, maximumPages: 4_096))
  var viewport = try FileByteViewport()
  let budget = viewport.storageBudgetBytes
  try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  #expect(viewport.visibleRange == 0..<fixture.bytes.count)
  #expect(viewport.rowRange(at: 0) == 0..<160 * cluster.utf8.count)
  #expect(viewport.byteRange(column: 159, row: 59, clamp: false) == fixture.bytes.count - 63..<fixture.bytes.count)
  #expect(source.residentPageCount == 1 && source.statistics.evictions > 0)
  #expect(viewport.storageBudgetBytes == budget)
  #expect(throws: FileDocumentError.invalidRange) {
    try viewport.begin(from: &source, firstByte: 0, size: .init(columns: 161, rows: 60))
  }
  #expect(viewport.visibleRange.upperBound == fixture.bytes.count && viewport.storageBudgetBytes == budget)
  let oversized = try UnicodeFileFixture(Array(("e" + String(repeating: "\u{301}", count: 80) + "Z").utf8))
  var overSource = try PagedFileDocument.open(
    oversized.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 64))
  try viewport.prepare(from: &overSource, firstByte: 0, size: .init(columns: 8, rows: 1))
  var surface = try Surface(maximumSize: .init(columns: 8, rows: 1))
  try surface.render(size: surface.maximumSize) { frame in
    viewport.paint(
      in: frame.area, frame: &frame, pageBytes: 4, previousRange: 0..<0,
      style: Style(), revealedStyle: Style(), boundaryStyle: Style())
    #expect(frame[0, 0].glyph == .replacement && frame[1, 0].glyph == .replacement)
    #expect(frame[2, 0].glyph == .replacement && frame[3, 0].glyph.scalar == "Z")
  }
}

@Test(arguments: ["abcdef", "Aé漢e\u{301}😀Z"])
func viewportRowHistoryRetainsDistinctRowsAcrossTrackpadDirectionChanges(pattern: String) throws {
  let fixture = try UnicodeFileFixture(Array(String(repeating: pattern, count: 8_192).utf8))
  let size = TerminalSize(columns: 80, rows: 30)
  var source = try PagedFileDocument.open(fixture.path)
  var viewport = try FileByteViewport(maximumSize: size)
  let budget = viewport.storageBudgetBytes
  try viewport.prepare(from: &source, firstByte: 0, size: size)
  var starts = [viewport.visibleRange.lowerBound]
  for _ in 0..<12 {
    let found = viewport.offset(scrollingRows: 3, from: viewport.visibleRange.lowerBound)
    let next = try #require(found)
    try viewport.prepare(from: &source, firstByte: next, size: size)
    starts.append(next)
  }
  for expected in starts.dropLast().reversed() {
    let found = viewport.offset(scrollingRows: -3, from: viewport.visibleRange.lowerBound)
    let previous = try #require(found)
    #expect(previous == expected)
    try viewport.prepare(from: &source, firstByte: previous, size: size)
  }
  #expect(viewport.visibleRange.lowerBound == 0 && viewport.storageBudgetBytes == budget)
}

@Test func unicodeCachedRowResumesWithoutReadingItsPagePrefix() throws {
  let fixture = try UnicodeFileFixture(Array((String(repeating: "Aé漢e\u{301}😀Z", count: 32_768)).utf8))
  let size = TerminalSize(columns: 80, rows: 30)
  var source = try PagedFileDocument.open(fixture.path, configuration: .init(cachePages: 1))
  var viewport = try FileByteViewport(maximumSize: size)
  try viewport.prepare(from: &source, firstByte: 120_000, size: size)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { frame in
    viewport.paint(
      in: frame.area, frame: &frame, pageBytes: 65_536, previousRange: 0..<0,
      style: Style(), revealedStyle: Style(), boundaryStyle: Style())
  }
  let expected = (0..<size.columns).map { surface.cell(x: $0, y: 1)! }
  let next = try #require(viewport.rowRange(at: 1)?.lowerBound)
  source.discardCachedPages()
  let before = source.statistics
  try viewport.prepare(from: &source, firstByte: next, size: size)
  #expect(source.statistics.loads - before.loads == 1)
  #expect(source.statistics.cacheHits - before.cacheHits <= UInt64(2 + (viewport.visibleRange.count + 4_095) / 4_096))
  try surface.render(size: size) { frame in
    viewport.paint(
      in: frame.area, frame: &frame, pageBytes: 65_536, previousRange: 0..<0,
      style: Style(), revealedStyle: Style(), boundaryStyle: Style())
    for column in 0..<size.columns { #expect(frame[column, 0] == expected[column]) }
  }
}

@Test func unicodeReverseReplayRefillsPredecessorsAndExpandsForLongRows() throws {
  let fixture = try UnicodeFileFixture(Array((String(repeating: "A", count: 400_000) + "漢").utf8))
  let size = TerminalSize(columns: 80, rows: 30)
  var source = try PagedFileDocument.open(fixture.path)
  var viewport = try FileByteViewport(maximumSize: size)
  let budget = viewport.storageBudgetBytes
  try viewport.prepare(from: &source, firstByte: 200_000, size: size)
  try viewport.begin(from: &source, firstByte: viewport.visibleRange.lowerBound, size: size, backwardRows: 3)
  while viewport.hasPendingWork { _ = try viewport.advance(from: &source) }
  for _ in 0..<16 {
    let found = viewport.offset(scrollingRows: -3, from: viewport.visibleRange.lowerBound)
    let previous = try #require(found)
    try viewport.prepare(from: &source, firstByte: previous, size: size)
  }
  #expect(viewport.storageBudgetBytes == budget)

  let cluster = "a" + String(repeating: "\u{301}", count: 31)
  let prefix = String(repeating: cluster, count: 6_400)
  let longRows = try UnicodeFileFixture(Array((prefix + String(repeating: "z", count: 10_000)).utf8))
  var longSource = try PagedFileDocument.open(longRows.path, configuration: .init(pageBytes: 256, cachePages: 1))
  let small = TerminalSize(columns: 32, rows: 4)
  try viewport.prepare(from: &longSource, firstByte: prefix.utf8.count, size: small)
  try viewport.begin(from: &longSource, firstByte: viewport.visibleRange.lowerBound, size: small, backwardRows: 60)
  for _ in 0..<65_536 {
    if !viewport.hasPendingWork { break }
    _ = try viewport.advance(from: &longSource)
  }
  let pending = viewport.hasPendingWork
  #expect(!pending)
  #expect(prefix.utf8.count - viewport.visibleRange.lowerBound >= 59 * small.columns * cluster.utf8.count)
  #expect(viewport.visibleRange.count == small.columns * small.rows * cluster.utf8.count)
  #expect(viewport.storageBudgetBytes == budget)
}

@Test func unicodeRowCheckpointsBelongToTheirFileAndColumnWidth() throws {
  let first = try UnicodeFileFixture(Array(String(repeating: "🇦", count: 101).utf8))
  let second = try UnicodeFileFixture(Array(("aaaa" + String(repeating: "🇦", count: 100)).utf8))
  let size = TerminalSize(columns: 2, rows: 4)
  var viewport = try FileByteViewport(maximumSize: size)
  var firstSource = try PagedFileDocument.open(first.path, configuration: .init(pageBytes: 4, cachePages: 1))
  var secondSource = try PagedFileDocument.open(second.path, configuration: .init(pageBytes: 4, cachePages: 1))
  try viewport.prepare(from: &firstSource, firstByte: 0, size: size)
  for _ in 0..<2 {
    try viewport.prepare(from: &secondSource, firstByte: 8, size: size)
    #expect(viewport.visibleRange.lowerBound == 4)
  }
  try viewport.prepare(from: &secondSource, firstByte: 8, size: .init(columns: 1, rows: 4))
  #expect(viewport.visibleRange.lowerBound == 4)
}

@Test(arguments: ["", "漢"])
func viewportTrackpadBurstsLetPendingReverseWorkFinish(suffix: String) throws {
  let fixture = try UnicodeFileFixture(Array((String(repeating: "a", count: 1_048_576) + suffix).utf8))
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 160, rows: 60)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  _ = viewer.handle(.character("9"), modifiers: [])
  viewer.prepare(in: size)
  try finishViewportPreparation(viewer)
  let start = viewer.firstByte
  let budget = viewer.storageBudgetBytes
  for _ in 0..<64 {
    _ = viewer.mouse(.init(action: .scrollUp, button: .none, column: layout.text.x, row: layout.text.y))
    viewer.prepare(in: size)
    _ = viewer.performPendingWork()
    if viewer.visibleRange.lowerBound < start { break }
  }
  #expect(viewer.visibleRange.lowerBound < start && viewer.notice.isEmpty)
  #expect(viewer.storageBudgetBytes == budget)
}

private struct UnicodeFileFixture: ~Copyable {
  let path: String
  let bytes: [UInt8]
  init(_ bytes: [UInt8]) throws {
    self.bytes = bytes
    path = NSTemporaryDirectory() + "slate-unicode-" + UUID().uuidString
    try Data(bytes).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }
  deinit { try? FileManager.default.removeItem(atPath: path) }
}
