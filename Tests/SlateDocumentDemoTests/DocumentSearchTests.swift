import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func searchMatchesAnIndependentByteOracleAcrossPageSeamsAndWrapOrigins() throws {
  let bytes = Array("ababacabaé漢👩🏽‍💻aba".utf8) + [0xff, 0x00] + Array("ababa".utf8)
  let fixture = try SearchFixture(bytes)
  for pageBytes in [4, 5, 7, 64] {
    var source = try PagedFileDocument.open(
      fixture.path, configuration: .init(pageBytes: pageBytes, cachePages: 1), content: .bytes)
    var search = DocumentSearch()
    let storage = search.storagePayloadBytes
    for query in ["a", "aba", "ababac", "é漢", "👩🏽‍💻", "ababa", "absent"] {
      let pattern = Array(query.utf8)
      let matches = (0...bytes.count - pattern.count).filter { offset in
        bytes[offset..<offset + pattern.count].elementsEqual(pattern)
      }
      for origin in 0...bytes.count {
        beginSearch(&search, query: query, firstByte: origin, byteCount: bytes.count)
        try finishSearch(&search, source: &source)
        let expected = matches.first(where: { $0 >= origin }) ?? matches.first
        #expect(search.match == expected.map { $0..<$0 + pattern.count })
        #expect(search.state == (expected == nil ? .notFound : .found))
        #expect(search.storagePayloadBytes == storage)
      }
    }
  }
}

@Test func searchBoundsEachBatchAndRetainsPrefixStateAcrossScratchBoundaries() throws {
  let text = String(repeating: "x", count: 4_094) + "ababababac" + String(repeating: "x", count: 4_096)
  let fixture = try SearchFixture(Array(text.utf8))
  var source = try PagedFileDocument.open(fixture.path)
  var search = DocumentSearch()
  beginSearch(&search, query: "ababac", byteCount: source.byteCount)
  let before = source.statistics
  #expect(search.advance(from: &source) == nil)
  #expect(search.nextByte == DocumentSearch.maximumBytesPerBatch && search.hasPendingWork)
  #expect(source.statistics.loads - before.loads == 1)
  #expect(search.advance(from: &source) == 4_098..<4_104)
  #expect(!search.hasPendingWork && search.state == .found)
}

@Test func searchHandlesEmptyFilesEmptyQueriesMaximumQueriesAndOverlappingNextMatches() throws {
  let empty = try SearchFixture([])
  var emptySource = try PagedFileDocument.open(empty.path)
  var search = DocumentSearch()
  beginSearch(&search, query: "", byteCount: 0)
  #expect(search.state == .idle && !search.hasPendingWork)
  beginSearch(&search, query: "a", byteCount: 0)
  #expect(search.state == .notFound && search.advance(from: &emptySource) == nil)
  #expect(emptySource.statistics.loads == 0)

  let fixture = try SearchFixture(Array(String(repeating: "a", count: 260).utf8))
  var source = try PagedFileDocument.open(fixture.path, configuration: .init(pageBytes: 4, cachePages: 1))
  let query = String(repeating: "a", count: DocumentSearch.maximumQueryBytes)
  beginSearch(&search, query: query, byteCount: source.byteCount)
  try finishSearch(&search, source: &source)
  #expect(search.match == 0..<256)
  var copy = CopyBuffer()
  _ = search.handle(.tab, modifiers: [], copyBuffer: &copy, firstByte: 0, byteCount: source.byteCount)
  for start in [1, 2, 3, 4, 0] {
    _ = search.handle(.character("n"), modifiers: [], copyBuffer: &copy, firstByte: 0, byteCount: source.byteCount)
    try finishSearch(&search, source: &source)
    #expect(search.match == start..<start + 256)
  }
}

@Test func searchRejectsOversizedOrInvalidPastesAtomicallyAndCancelsWithoutMoreReads() throws {
  let fixture = try SearchFixture(Array(String(repeating: "a", count: 10_000).utf8))
  var source = try PagedFileDocument.open(fixture.path)
  var search = DocumentSearch()
  beginSearch(&search, query: "missing", byteCount: source.byteCount)
  let query = search.input.snapshot()
  #expect(search.paste(String(repeating: "x", count: 257).utf8Span, byteCount: source.byteCount) == .redraw)
  #expect(search.input.snapshot() == query && search.inputError == .capacityExceeded)
  #expect(search.paste("\u{1b}".utf8Span, byteCount: source.byteCount) == .redraw)
  #expect(search.input.snapshot() == query && search.inputError == .invalidControl)
  _ = search.advance(from: &source)
  let pendingBeforeCancellation = search.hasPendingWork
  try #require(pendingBeforeCancellation)
  var copy = CopyBuffer()
  #expect(search.handle(.escape, modifiers: [], copyBuffer: &copy, firstByte: 0, byteCount: source.byteCount) == .redraw)
  let statistics = source.statistics
  #expect(!search.hasPendingWork && !search.isVisible && !search.isFocused && search.match == nil)
  #expect(search.state == .cancelled && search.advance(from: &source) == nil)
  #expect(source.statistics == statistics)
}

@Test func searchLatchesFileMutationWithoutPublishingAMatchOrRetrying() throws {
  let fixture = try SearchFixture(Array(String(repeating: "a", count: 8_192).utf8) + Array("target".utf8))
  var source = try PagedFileDocument.open(fixture.path)
  var search = DocumentSearch()
  beginSearch(&search, query: "target", byteCount: source.byteCount)
  #expect(search.advance(from: &source) == nil && search.hasPendingWork)
  let file = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
  try file.truncate(atOffset: 1)
  try file.close()
  #expect(search.advance(from: &source) == nil)
  #expect(search.state == .failed(.fileChanged) && search.match == nil && !search.hasPendingWork)
  let statistics = source.statistics
  #expect(search.advance(from: &source) == nil && source.statistics == statistics)
}

@Test func searchRoutesFocusTypingPasteNavigationAndQuitThroughTheApplication() throws {
  let fixture = try SearchFixture(Array("start target middle target end".utf8))
  var application = SlateDocumentDemo(path: fixture.path)
  _ = application.performPendingWork()
  let size = TerminalSize(columns: 80, rows: 24)
  _ = application.render(in: size)
  var copy = CopyBuffer()
  #expect(application.event(.key(.character("/")), copyBuffer: &copy) == .redraw)
  // Viewer commands are literal text while the search field has focus.
  #expect(application.event(.key(.character("q")), copyBuffer: &copy) == .redraw)
  _ = application.event(.key(.control(.a)), copyBuffer: &copy)
  #expect(application.event(.paste("target".utf8Span), copyBuffer: &copy) == .redraw)
  try finishApplicationWork(&application, size: size)
  #expect(application.event(.key(.tab), copyBuffer: &copy) == .redraw)
  #expect(application.event(.key(.down), copyBuffer: &copy) == .redraw)
  #expect(application.event(.key(.character("n")), copyBuffer: &copy) == .redraw)
  try finishApplicationWork(&application, size: size)
  #expect(application.event(.key(.escape), copyBuffer: &copy) == .redraw)
  #expect(application.event(.key(.character("q")), copyBuffer: &copy) == .quit)
}

@Test func searchBlocksSurviveCustomPaintingAndResizeAndHighlightWholeUnicodeGlyphs() throws {
  let fixture = try SearchFixture(Array((String(repeating: "x", count: 1_000) + "é漢👩🏽‍💻tail").utf8))
  let viewer = try DocumentFileViewer(fixture.path, configuration: .init(pageBytes: 4, cachePages: 1))
  let size = TerminalSize(columns: 80, rows: 24)
  _ = viewer.render(in: size)
  try finishViewportPreparation(viewer)
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("/")), copyBuffer: &copy)
  #expect(viewer.searchVisible && viewer.searchFocused)
  _ = viewer.event(.paste("漢👩🏽‍💻".utf8Span), copyBuffer: &copy)
  for _ in 0..<4_096 {
    _ = viewer.render(in: size)
    if !viewer.hasPendingWork { break }
    _ = viewer.performPendingWork()
  }
  try #require(!viewer.hasPendingWork && viewer.searchState == .found)
  #expect(viewer.searchMatch == 1_002..<1_020)
  var surface = try Surface(maximumSize: .init(columns: 160, rows: 60), nodeCapacity: SlateDocumentDemo.configuration.nodeCapacity)
  try surface.render(size: size) { viewer.render(in: size) } paint: { viewer.paint(in: &$0) }
  #expect(surface.cell(x: 0, y: 22)?.glyph.scalar == "/")
  let queryGlyph = try #require(surface.cell(x: 2, y: 22)?.glyph)
  #expect(String(copying: queryGlyph.utf8()) == "漢")
  let layout = DocumentViewerLayout(size: .init(columns: 80, rows: 22), byteCount: fixture.bytes.count, showInspector: true)
  let highlights = (0..<layout.text.height).flatMap { row in
    (0..<layout.text.width).filter { column in
      surface.cell(x: layout.text.x + column, y: layout.text.y + row)?.style.background == ViewerPalette.match.background
    }
  }
  #expect(highlights.count == 4)
  _ = viewer.event(.key(.tab), copyBuffer: &copy)
  #expect(!viewer.searchFocused)
  _ = viewer.event(.mouse(.init(action: .press, button: .left, column: 2, row: 22)), copyBuffer: &copy)
  #expect(viewer.searchFocused)
  for smallSize in [TerminalSize(columns: 0, rows: 0), .init(columns: 1, rows: 1), .init(columns: 16, rows: 7), surface.maximumSize] {
    try surface.render(size: smallSize) { viewer.render(in: smallSize) } paint: { viewer.paint(in: &$0) }
    try finishViewportPreparation(viewer)
    #expect(viewer.searchMatch == 1_002..<1_020)
  }
}

private func beginSearch(_ search: inout DocumentSearch, query: String, firstByte: Int = 0, byteCount: Int) {
  var copy = CopyBuffer()
  if search.isVisible { search.close() }
  _ = search.handle(.character("/"), modifiers: [], copyBuffer: &copy, firstByte: firstByte, byteCount: byteCount)
  _ = search.paste(query.utf8Span, byteCount: byteCount)
}

private func finishSearch(_ search: inout DocumentSearch, source: inout PagedFileDocument) throws {
  for _ in 0..<4_096 {
    if !search.hasPendingWork { return }
    let before = source.statistics
    _ = search.advance(from: &source)
    #expect(source.statistics.loads - before.loads <= 1)
  }
  let unfinished = search.hasPendingWork
  try #require(!unfinished)
}

private struct SearchFixture: ~Copyable {
  let path: String
  let bytes: [UInt8]

  init(_ bytes: [UInt8]) throws {
    self.bytes = bytes
    path = NSTemporaryDirectory() + "slate-search-" + UUID().uuidString
    try Data(bytes).write(to: URL(fileURLWithPath: path))
  }

  deinit { try? FileManager.default.removeItem(atPath: path) }
}
