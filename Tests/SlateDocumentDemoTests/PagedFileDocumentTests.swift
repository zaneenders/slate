import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func pagedFileMatchesBufferAcrossUTF8AndCRLFPageBoundaries() throws {
  for text in ["", "a", "a\n", "\r", "\r\n", "\r\r\n\n", "é\r\n👩‍💻x\rrest\nlast\r\n", "x\0\t\u{1b}"] {
    let fixture = try PagedFileFixture(Array(text.utf8))
    let reference = try DocumentBuffer(text)
    for pageBytes in 4...13 {
      var source = try PagedFileDocument.open(
        fixture.path,
        configuration: .init(pageBytes: pageBytes, cachePages: 1, maximumPages: 32))
      #expect(source.residentPageCount == 0)
      #expect(source.byteCount == reference.byteCount && source.lineCount == reference.lineCount)
      for line in 0..<reference.lineCount {
        #expect(try source.lineContentRange(at: line) == reference.lineRange(at: line))
        #expect(source.residentPageCount <= 1)
      }
      var output = InlineArray<7, UInt8>(repeating: 0)
      var copied: [UInt8] = []
      while copied.count < source.byteCount {
        let count = try source.readUTF8(from: copied.count, into: output.mutableSpan)
        #expect(count > 0 && count <= 7)
        for index in 0..<count { copied.append(output[index]) }
      }
      #expect(copied == Array(text.utf8))
      #expect(try source.readUTF8(from: source.byteCount, into: output.mutableSpan) == 0)
      #expect(throws: FileDocumentError.invalidRange) { try source.readUTF8(from: -1, into: output.mutableSpan) }
      #expect(throws: FileDocumentError.invalidLine) { try source.lineContentRange(at: source.lineCount) }
    }
  }
}

@Test func pagedFileCacheReusesHitsEvictsLeastRecentlyUsedAndKeepsItsBudget() throws {
  let fixture = try PagedFileFixture(Array(repeating: 0x78, count: 256))
  var source = try PagedFileDocument.open(
    fixture.path,
    configuration: .init(pageBytes: 64, cachePages: 2, maximumPages: 4))
  let budget = source.cacheStorageBudgetBytes
  var output = InlineArray<1, UInt8>(repeating: 0)
  for offset in [0, 0, 64, 0, 128, 0] {
    _ = try source.readUTF8(from: offset, into: output.mutableSpan)
    #expect(output[0] == 0x78)
  }
  #expect(source.statistics.loads == 3 && source.statistics.evictions == 1)
  #expect(source.statistics.cacheHits == 3)
  #expect(source.statistics.bytesRead == 192 && source.residentPageCount == 2)
  _ = try source.readUTF8(from: 64, into: output.mutableSpan)
  #expect(source.statistics.loads == 4 && source.statistics.evictions == 2)
  #expect(source.residentPageCount == 2 && source.cacheStorageBudgetBytes == budget)
  #expect(source.indexedPageCount == 4)
}

@Test func pagedFileRopeFindsLinesAcrossMultipleIndexLevels() throws {
  let text = (0..<2_048).map { "line \($0)\r\n" }.joined()
  let fixture = try PagedFileFixture(Array(text.utf8))
  let reference = try DocumentBuffer(text)
  var source = try PagedFileDocument.open(
    fixture.path,
    configuration: .init(pageBytes: 64, cachePages: 2, maximumPages: 512))
  #expect(source.indexedPageCount > 200 && source.lineCount == 2_049)
  for line in [0, 1, 14, 15, 16, 127, 128, 1_023, 2_047, 2_048, 42, 500, 0] {
    #expect(try source.lineContentRange(at: line) == reference.lineRange(at: line))
    #expect(source.residentPageCount <= 2)
  }
}

@Test func pagedFileColdCacheRetainsStorageAndStatisticsAndReloadsTheSameBytes() throws {
  let fixture = try PagedFileFixture(Array(repeating: 0x78, count: 256))
  var source = try PagedFileDocument.open(
    fixture.path, configuration: .init(pageBytes: 64, cachePages: 2, maximumPages: 4))
  let budget = source.cacheStorageBudgetBytes
  var output = InlineArray<1, UInt8>(repeating: 0)
  _ = try source.readUTF8(from: 128, into: output.mutableSpan)
  #expect(source.cachedPageNumber(at: 0) == 2)
  #expect(source.cachedPageNumber(at: -1) == nil && source.cachedPageNumber(at: 2) == nil)
  let statistics = source.statistics
  source.discardCachedPages()
  #expect(source.residentPageCount == 0 && source.cachedPageNumber(at: 0) == nil)
  #expect(source.cacheStorageBudgetBytes == budget && source.statistics == statistics)
  _ = try source.readUTF8(from: 128, into: output.mutableSpan)
  #expect(output[0] == 0x78 && source.statistics.loads == statistics.loads + 1)
  #expect(source.statistics.evictions == statistics.evictions)
}

@Test func pagedFileIndexHandlesTheDefaultMaximumAndRejectsAdditionalDescriptors() throws {
  let capacity = FileDocumentConfiguration().maximumPages
  var index = FilePageIndex(capacity: capacity)
  for page in 0..<capacity {
    try index.append(
      .init(
        fileOffset: page * 65_536, byteCount: 65_536,
        breakCount: 1, previousWasCR: false, checksum: 0))
  }
  #expect(index.pageCount == capacity && index.byteCount == 4_294_967_296 && index.breakCount == capacity)
  for page in [0, 1, 15, 256, 32_768, capacity - 1] {
    #expect(index.page(atByteOffset: page * 65_536 + 65_535).fileOffset == page * 65_536)
    let found = index.page(containingBreak: page)
    #expect(found.page.fileOffset == page * 65_536 && found.localOrdinal == 0)
  }
  #expect(throws: FileDocumentError.indexCapacityExceeded) {
    try index.append(
      .init(
        fileOffset: index.byteCount, byteCount: 1,
        breakCount: 0, previousWasCR: false, checksum: 0))
  }
  #expect(index.pageCount == capacity && index.byteCount == 4_294_967_296)
}

@Test func pagedFileViewportSkipsAMegabyteLineWithOneResidentPageAndNoPaintingIO() throws {
  let text = String(repeating: "x", count: 1_048_576) + "\nlast"
  let fixture = try PagedFileFixture(Array(text.utf8))
  var source = try PagedFileDocument.open(
    fixture.path,
    configuration: .init(pageBytes: 4_096, cachePages: 1, maximumPages: 512))
  var viewport = try TextViewport(maximumSize: TerminalSize(columns: 16, rows: 2), maximumReadBytes: 128)
  try viewport.prepare(from: &source, size: viewport.maximumSize)
  #expect(source.indexedPageCount == 257 && source.residentPageCount == 1)
  #expect(source.cacheStorageBudgetBytes < 21_000)
  #expect(source.statistics.bytesRead <= 4 * 4_096)
  #expect(viewport.lastReadByteCount == 68)
  #expect(viewport.cell(x: 15, y: 0)?.glyph.scalar == "x")
  #expect(viewport.cell(x: 0, y: 1)?.glyph.scalar == "l")
  #expect(viewport.cell(x: 3, y: 1)?.glyph.scalar == "t")
  let statistics = source.statistics
  var surface = try Surface(maximumSize: viewport.maximumSize)
  try surface.render(size: surface.maximumSize) { frame in viewport.paint(in: frame.area, frame: &frame) }
  #expect(source.statistics == statistics)
}

@Test func pagedFileRejectsMalformedUTF8AcrossPages() throws {
  for invalid: [UInt8] in [
    [0x80], [0xc0, 0xaf], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80],
    [0xf4, 0x90, 0x80, 0x80], [0xf0, 0x9f]
  ] {
    let fixture = try PagedFileFixture([0x61, 0x61, 0x61] + invalid)
    #expect(throws: FileDocumentError.invalidUTF8(byteOffset: 3)) {
      _ = try PagedFileDocument.open(
        fixture.path,
        configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 8))
    }
  }
}

@Test func pagedFileBytePolicyPreservesMalformedBytesAndRejectsTextAccess() throws {
  for invalid: [UInt8] in [
    [0x80], [0xc0, 0xaf], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80],
    [0xf4, 0x90, 0x80, 0x80], [0xf0, 0x9f]
  ] {
    let bytes: [UInt8] = [0x00, 0x1b, 0x41] + invalid
    let fixture = try PagedFileFixture(bytes)
    var source = try PagedFileDocument.open(
      fixture.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 2), content: .bytes)
    #expect(source.byteCount == bytes.count && source.residentPageCount == 0)
    var output = InlineArray<8, UInt8>(repeating: 0)
    var offset = 0
    while offset < bytes.count {
      let count = try source.readBytes(from: offset, into: output.mutableSpan)
      try #require(count > 0 && count <= 4)
      for index in 0..<count { #expect(output[index] == bytes[offset + index]) }
      offset += count
    }
    #expect(try source.readBytes(from: bytes.count, into: output.mutableSpan) == 0)
    #expect(throws: FileDocumentError.invalidRange) { try source.readBytes(from: -1, into: output.mutableSpan) }
    #expect(throws: FileDocumentError.invalidRange) { try source.readBytes(from: bytes.count + 1, into: output.mutableSpan) }
    let statistics = source.statistics
    #expect(throws: FileDocumentError.invalidUTF8(byteOffset: 3)) { try source.validateSnapshot() }
    #expect(throws: FileDocumentError.invalidUTF8(byteOffset: 3)) { try source.lineContentRange(at: 0) }
    #expect(throws: FileDocumentError.invalidUTF8(byteOffset: 3)) { try source.readUTF8(from: 0, into: output.mutableSpan) }
    var viewport = try TextViewport(maximumSize: .init(columns: 8, rows: 1))
    #expect(throws: TextViewportError<FileDocumentError>.source(.invalidUTF8(byteOffset: 3))) {
      try viewport.prepare(from: &source, size: viewport.maximumSize)
    }
    #expect(source.statistics == statistics)
  }
  let tooLarge = try PagedFileFixture([0xff, 0xff, 0xff, 0xff, 0xff])
  #expect(throws: FileDocumentError.indexCapacityExceeded) {
    _ = try PagedFileDocument.open(
      tooLarge.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 1), content: .bytes)
  }
}

@Test func pagedFileRejectsIndexExhaustionInvalidConfigurationsAndNonFiles() throws {
  let fixture = try PagedFileFixture(Array("12345".utf8))
  #expect(throws: FileDocumentError.indexCapacityExceeded) {
    _ = try PagedFileDocument.open(
      fixture.path,
      configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 1))
  }
  for configuration in [
    FileDocumentConfiguration(pageBytes: 0), .init(pageBytes: 3), .init(pageBytes: 1_048_577),
    .init(cachePages: 0), .init(cachePages: 65), .init(maximumPages: 0), .init(maximumPages: 1_048_577),
    .init(pageBytes: 1_048_576, cachePages: 64)
  ] {
    #expect(throws: FileDocumentError.invalidConfiguration) {
      _ = try PagedFileDocument.open(fixture.path, configuration: configuration)
    }
  }
  #expect(throws: FileDocumentError.invalidPath) { _ = try PagedFileDocument.open("bad\0path") }
  #expect(throws: FileDocumentError.notRegularFile) { _ = try PagedFileDocument.open(NSTemporaryDirectory()) }
  #expect(throws: FileDocumentError.open(errno: POSIXErrorCode.ENOENT.rawValue)) {
    _ = try PagedFileDocument.open(fixture.path + ".missing")
  }
  // FilePath removes trailing separators. Passing the original path spelling
  // to open must still reject a regular file used as a directory.
  for suffix in ["/", "//", "/."] {
    #expect(throws: FileDocumentError.open(errno: POSIXErrorCode.ENOTDIR.rawValue)) {
      _ = try PagedFileDocument.open(fixture.path + suffix)
    }
  }
}

@Test func pagedFileDetectsMutationAndPreservesThePreviousViewport() throws {
  let fixture = try PagedFileFixture(Array("abc\ndef".utf8))
  var source = try PagedFileDocument.open(
    fixture.path,
    configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 2))
  var viewport = try TextViewport(maximumSize: TerminalSize(columns: 3, rows: 2))
  try viewport.prepare(from: &source, size: viewport.maximumSize)
  try fixture.overwrite(Array("XYZ".utf8), at: 0)
  #expect(throws: FileDocumentError.fileChanged) { try source.verifyUnchanged() }
  #expect(throws: TextViewportError<FileDocumentError>.source(.fileChanged)) {
    try viewport.prepare(from: &source, size: viewport.maximumSize)
  }
  #expect(viewport.cell(x: 0, y: 0)?.glyph.scalar == "a")
  #expect(viewport.cell(x: 0, y: 1)?.glyph.scalar == "d")
}

@Test func pagedFileChecksPageContentBeforePublishingAReusedCacheSlot() throws {
  let fixture = try PagedFileFixture(Array("abc\ndef\n".utf8))
  var source = try PagedFileDocument.open(
    fixture.path,
    configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 2))
  var output = InlineArray<1, UInt8>(repeating: 0)
  _ = try source.readUTF8(from: 0, into: output.mutableSpan)
  try fixture.overwrite(Array("XYZ".utf8), at: 4)
  #expect(throws: FileDocumentError.fileChanged) { try source.readUTF8(from: 4, into: output.mutableSpan) }
  #expect(source.residentPageCount == 0)
  #expect(source.statistics.loads == 1)
}

@Test func pagedFileDetectsTruncationAndViewerNavigationRemainsInTheDemo() throws {
  let fixture = try PagedFileFixture(Array("first\nsecond\nthird".utf8))
  let viewer = try DocumentFileViewer(
    fixture.path,
    configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 8))
  viewer.prepare(in: TerminalSize(columns: 40, rows: 7))
  #expect(viewer.handle(.end, modifiers: []) == .redraw)
  viewer.prepare(in: TerminalSize(columns: 40, rows: 7))
  #expect(viewer.visibleRange.upperBound == 18)
  #expect(viewer.handle(.character("0"), modifiers: []) == .redraw && viewer.firstByte == 0)
  #expect(viewer.handle(.character("9"), modifiers: []) == .redraw && viewer.firstByte == 15)
  #expect(viewer.handle(.character("q"), modifiers: []) == .quit)
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
  try handle.truncate(atOffset: 0)
  try handle.close()
  viewer.prepare(in: TerminalSize(columns: 40, rows: 7))
  #expect(viewer.notice.contains("File changed"))
  let range = viewer.visibleRange
  let stats = viewer.statistics
  #expect(viewer.handle(.down, modifiers: []) == .none)
  #expect(viewer.handle(.character("C"), modifiers: []) == .none)
  viewer.prepare(in: TerminalSize(columns: 40, rows: 7))
  #expect(viewer.visibleRange == range && viewer.statistics == stats)
  #expect(viewer.handle(.character("?"), modifiers: []) == .redraw)
  #expect(viewer.handle(.escape, modifiers: []) == .redraw)
  #expect(viewer.handle(.character("q"), modifiers: []) == .quit)
  var surface = try Surface(maximumSize: TerminalSize(columns: 40, rows: 7))
  try surface.render(size: surface.maximumSize) { frame in viewer.paint(in: &frame) }
}

@Test func pagedFileIndexProgressReportsBytesWithoutWarmingTheCache() throws {
  for bytes in [[], Array("pi: 3.243f6a8885a308d3".utf8)] {
    let fixture = try PagedFileFixture(bytes)
    var updates: [Int] = []
    let source = try PagedFileDocument.open(
      fixture.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 8),
      progress: { complete, total in
        #expect(total == bytes.count)
        updates.append(complete)
      })
    #expect(updates == (bytes.isEmpty ? [0] : [0, bytes.count]))
    #expect(source.residentPageCount == 0 && source.statistics.loads == 0 && source.statistics.bytesRead == 0)
  }
}

private struct PagedFileFixture: ~Copyable {
  private let url: URL
  var path: String { url.path }

  init(_ bytes: [UInt8]) throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slate-paging-" + UUID().uuidString)
    try Data(bytes).write(to: url, options: .withoutOverwriting)
  }

  borrowing func overwrite(_ bytes: [UInt8], at offset: UInt64) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    try handle.write(contentsOf: Data(bytes))
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}
