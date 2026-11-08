import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func incrementalIndexingPreservesUTF8AndCRLFStateAcrossBatches() throws {
  let text = "ab\r\n\u{1f600}é\r\nlast\r"
  let fixture = try IndexFixture(Array(text.utf8))
  var indexer = try PagedFileDocument.Indexer(
    fixture.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 16))
  #expect(indexer.indexedByteCount == 0 && indexer.indexedPageCount == 0 && !indexer.isComplete)
  for _ in 0..<16 {
    let before = indexer.indexedByteCount
    try indexer.advance(maximumPages: 1)
    #expect(indexer.indexedByteCount - before <= 4)
    if indexer.isComplete { break }
  }
  let complete = indexer.isComplete
  try #require(complete)
  let pages = indexer.indexedPageCount
  try indexer.advance()  // Completed advancement is idempotent.
  #expect(indexer.indexedPageCount == pages)
  var source = indexer.finish()
  let reference = try DocumentBuffer(text)
  #expect(source.byteCount == reference.byteCount && source.lineCount == reference.lineCount)
  #expect(source.residentPageCount == 0 && source.statistics.bytesRead == 0)
  for line in 0..<reference.lineCount {
    #expect(try source.lineContentRange(at: line) == reference.lineRange(at: line))
  }
}

@Test func incrementalIndexingBoundsPagesAndBytesAndRejectsInvalidBatchSizes() throws {
  let fixture = try IndexFixture(Array(repeating: 0x61, count: 5_242_880))
  var indexer = try PagedFileDocument.Indexer(
    fixture.path, configuration: .init(pageBytes: 1_048_576, cachePages: 1, maximumPages: 5))
  for invalid in [0, 65] {
    #expect(throws: FileDocumentError.invalidConfiguration) { try indexer.advance(maximumPages: invalid) }
    #expect(indexer.indexedByteCount == 0)
  }
  for _ in 0..<5 {
    let bytes = indexer.indexedByteCount
    let pages = indexer.indexedPageCount
    try indexer.advance()
    #expect(indexer.indexedByteCount - bytes <= PagedFileDocument.Indexer.maximumBytesPerBatch)
    #expect(indexer.indexedPageCount - pages <= PagedFileDocument.Indexer.maximumPagesPerBatch)
    if indexer.isComplete { break }
  }
  #expect(indexer.isComplete && indexer.indexedPageCount == 5)
}

@Test func incrementalIndexingLatchesSplitScalarFailuresAndDetectsMutation() throws {
  let invalid = try IndexFixture([0x61, 0x61, 0x61, 0xe0, 0x80, 0x80])
  var indexer = try PagedFileDocument.Indexer(
    invalid.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 2))
  try indexer.advance(maximumPages: 1)
  #expect(indexer.indexedByteCount == 4 && !indexer.isComplete)
  #expect(throws: FileDocumentError.invalidUTF8(byteOffset: 3)) { try indexer.advance(maximumPages: 1) }
  #expect(!indexer.isComplete && indexer.indexedByteCount == 4)
  #expect(throws: FileDocumentError.invalidUTF8(byteOffset: 3)) { try indexer.advance() }

  let changing = try IndexFixture(Array("abcdefghi".utf8))
  var changed = try PagedFileDocument.Indexer(
    changing.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 3))
  try changed.advance(maximumPages: 1)
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: changing.path))
  try handle.truncate(atOffset: 1)
  try handle.close()
  #expect(throws: FileDocumentError.fileChanged) { try changed.advance() }
  #expect(changed.indexedByteCount == 4 && !changed.isComplete)
}

@Test func incrementalByteIndexingContinuesAfterMalformedUTF8AcrossBatches() throws {
  let bytes: [UInt8] = [0x61, 0x61, 0x61, 0xe0, 0x80, 0x80, 0x0d, 0x0a, 0xff, 0x00, 0x41, 0xf0, 0x9f]
  let fixture = try IndexFixture(bytes)
  var indexer = try PagedFileDocument.Indexer(
    fixture.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 4), content: .bytes)
  for page in 1...4 {
    try indexer.advance(maximumPages: 1)
    #expect(indexer.indexedByteCount == min(page * 4, bytes.count))
    #expect(indexer.indexedPageCount == page && indexer.isComplete == (page == 4))
  }
  var source = indexer.finish()
  #expect(source.lineCount == 2 && source.residentPageCount == 0)
  var output = InlineArray<4, UInt8>(repeating: 0)
  #expect(try source.readBytes(from: 8, into: output.mutableSpan) == 4)
  #expect(output[0] == 0xff && output[1] == 0x00 && output[2] == 0x41 && output[3] == 0xf0)
  #expect(throws: FileDocumentError.invalidUTF8(byteOffset: 3)) { try source.validateSnapshot() }
}

@Test func indexingScreenDrawsBeforeScanningAndRemainsClippedOnResize() throws {
  let fixture = try IndexFixture(Array("pi: 3.243f6a8885a308d3".utf8))
  let application = SlateDocumentDemo(path: fixture.path)
  let progress = try #require(application.indexingProgress)
  #expect(application.hasPendingWork && progress.indexedBytes == 0 && progress.indexedPages == 0)
  #expect(progress.totalBytes == 22)
  var surface = try Surface(maximumSize: .init(columns: 160, rows: 60))
  for size in [
    TerminalSize(columns: 0, rows: 0), .init(columns: 1, rows: 1), .init(columns: 36, rows: 12),
    .init(columns: 40, rows: 24), .init(columns: 80, rows: 24), surface.maximumSize
  ] {
    _ = application.render(in: size)
    try surface.render(size: size) { application.paint(in: &$0) }
    #expect(application.indexingProgress == progress)
  }
  let title = (0..<20).map { surface.cell(x: $0, y: 3)!.glyph.scalar }.map(String.init).joined()
  #expect(title.contains("INDEXING FILE"))
}

@Test func indexingScreenTransitionsToViewerAndSupportsCancellationBeforeReading() throws {
  for text in ["", "3.243f6a8885a308d3"] {
    let fixture = try IndexFixture(Array(text.utf8))
    var application = SlateDocumentDemo(path: fixture.path)
    #expect(application.performPendingWork() == .redraw)
    #expect(!application.hasPendingWork && application.indexingProgress == nil)
    #expect(application.performPendingWork() == .none)
    let size = TerminalSize(columns: 80, rows: 24)
    _ = application.render(in: size)
    var surface = try Surface(maximumSize: size)
    try surface.render(size: size) { application.paint(in: &$0) }
    let title = (0..<20).map { surface.cell(x: $0, y: 3)!.glyph.scalar }.map(String.init).joined()
    #expect(title.contains("FILE BYTES"))
  }
  // Cancellation stops work before the first indexing read.
  let invalid = try IndexFixture([0xff])
  for key in [InputKey.character("q"), .escape, .control(.c), .control(.q)] {
    var application = SlateDocumentDemo(path: invalid.path)
    var copy = CopyBuffer()
    #expect(application.indexingProgress?.indexedBytes == 0)
    #expect(application.event(.key(key, modifiers: []), copyBuffer: &copy) == .quit)
    #expect(!application.hasPendingWork && application.indexingProgress == nil)
    #expect(application.performPendingWork() == .none)
  }
  let partial = try IndexFixture(Array(repeating: 0x61, count: 4_096))
  var application = SlateDocumentDemo(
    path: partial.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 1_024))
  _ = application.performPendingWork()
  #expect(application.hasPendingWork && application.indexingProgress!.indexedBytes > 0)
  var copy = CopyBuffer()
  #expect(application.event(.key(.escape, modifiers: []), copyBuffer: &copy) == .quit)
  #expect(!application.hasPendingWork && application.indexingProgress == nil)
}

@Test func indexingErrorsArePresentedInTheUIAndStopWork() throws {
  let fixture = try IndexFixture([0x61, 0xf0, 0x9f])
  var application = SlateDocumentDemo(path: fixture.path)
  #expect(application.hasPendingWork)
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
  try handle.truncate(atOffset: 0)
  try handle.close()
  #expect(application.performPendingWork() == .redraw)
  #expect(!application.hasPendingWork)
  #expect(application.performPendingWork() == .none)
  var surface = try Surface(maximumSize: .init(columns: 80, rows: 24))
  try surface.render(size: surface.maximumSize) { application.paint(in: &$0) }
  let message = (0..<50).map { surface.cell(x: $0, y: 0)!.glyph.scalar }.map(String.init).joined()
  #expect(message.contains("File changed"))
}

@Test func indexingScreenOpensBinaryAndTruncatedUTF8InTheByteViewer() throws {
  for bytes: [UInt8] in [[0xcf, 0xfa, 0xed, 0xfe, 0x00, 0x41, 0x1b, 0xff], [0x61, 0xf0, 0x9f]] {
    let fixture = try IndexFixture(bytes)
    var application = SlateDocumentDemo(
      path: fixture.path, configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 2))
    #expect(application.performPendingWork() == .redraw)
    #expect(!application.hasPendingWork && application.indexingProgress == nil)
    let size = TerminalSize(columns: 80, rows: 24)
    let layout = DocumentViewerLayout(size: size, byteCount: bytes.count, showInspector: true)
    _ = application.render(in: size)
    var surface = try Surface(maximumSize: size)
    try surface.render(size: size) { application.paint(in: &$0) }
    for (index, byte) in bytes.enumerated() {
      let scalar = (0x20...0x7e).contains(byte) ? Unicode.Scalar(byte) : "."
      #expect(surface.cell(x: layout.text.x + index, y: layout.text.y)?.glyph.scalar == scalar)
    }
    #expect(surface.cell(x: layout.text.x + bytes.count, y: layout.text.y)?.glyph.scalar == " ")
  }
}

private struct IndexFixture: ~Copyable {
  let path: String
  init(_ bytes: [UInt8]) throws {
    path = NSTemporaryDirectory() + "slate-index-" + UUID().uuidString
    try Data(bytes).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }
  deinit { try? FileManager.default.removeItem(atPath: path) }
}
