import Slate
import Testing

@testable import SlateDocumentDemo

@Test func byteViewportInvalidatesUnicodeRowHistoryAfterSameLengthEdits() throws {
  var source = MutableByteSource("abcdefgh")
  let size = TerminalSize(columns: 4, rows: 2)
  var viewport = try FileByteViewport(maximumSize: size)
  try viewport.prepare(from: &source, firstByte: 0, size: size)
  #expect(viewport.rowRange(at: 1)?.lowerBound == 4)
  let budget = viewport.storageBudgetBytes
  source.bytes = Array("abcédef".utf8)
  source.editRevision += 1
  // Offset four used to be a row boundary; it is now inside é. Reusing the old
  // checkpoint would publish a malformed continuation byte instead of é.
  try viewport.prepare(from: &source, firstByte: 4, size: size)
  #expect(viewport.visibleRange.lowerBound == 3)
  #expect(viewport.byteRange(column: 0, row: 0, clamp: false) == 3..<5)
  #expect(viewport.byte(at: 0) == 0xc3 && viewport.byte(at: 1) == 0xa9)
  #expect(viewport.storageBudgetBytes == budget)
}

@Test func byteViewportRejectsAnEditBetweenPreparationBatchesAndPreservesPublishedBytes() throws {
  var source = MutableByteSource("abcdefghijklmnop")
  let size = TerminalSize(columns: 4, rows: 2)
  var viewport = try FileByteViewport(maximumSize: size)
  try viewport.prepare(from: &source, firstByte: 0, size: size)
  let published = viewport.visibleRange
  try viewport.begin(from: &source, firstByte: 8, size: size)
  #expect(try !viewport.advance(from: &source, maximumScalars: 1))
  source.bytes[8] = 0x5a
  source.editRevision += 1
  #expect(throws: FileDocumentError.fileChanged) { try viewport.advance(from: &source) }
  #expect(!viewport.hasPendingWork && viewport.visibleRange == published)
  #expect(viewport.byte(at: 0) == 0x61)
}

@Test(arguments: [false, true])
func searchRejectsLogicalEditsBetweenBatchesEvenWhenLengthIsUnchanged(changesLength: Bool) throws {
  var source = MutableByteSource(String(repeating: "x", count: 8_192))
  var search = DocumentSearch()
  var copy = CopyBuffer()
  _ = search.handle(.character("/"), modifiers: [], copyBuffer: &copy, firstByte: 0, byteCount: source.byteCount)
  _ = search.paste("missing".utf8Span, byteCount: source.byteCount)
  #expect(search.advance(from: &source) == nil && search.hasPendingWork)
  if changesLength { source.bytes.removeLast() } else { source.bytes[0] = 0x5a }
  source.editRevision += 1
  #expect(search.advance(from: &source) == nil)
  #expect(search.state == .failed(.fileChanged) && search.match == nil && !search.hasPendingWork)
}

private struct MutableByteSource: FileByteSource {
  var bytes: [UInt8]
  var editRevision: UInt64 = 0
  var byteCount: Int { bytes.count }
  let snapshotIdentity: DocumentFileIdentity

  init(_ text: String) {
    bytes = Array(text.utf8)
    snapshotIdentity = .init(
      device: .init(rawValue: 0), inode: .init(rawValue: 0), byteCount: bytes.count, modificationSeconds: 0,
      modificationNanoseconds: 0, changeSeconds: 0, changeNanoseconds: 0)
  }

  func verifyUnchanged() throws(FileDocumentError) {}
  func unicodeCheckpoint(before offset: Int) -> FileUnicodeCheckpoint { .init() }

  func readBytes(
    from byteOffset: Int, maximumCount: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(FileDocumentError) -> Int {
    guard (0...byteCount).contains(byteOffset), maximumCount >= 0 else { throw .invalidRange }
    var buffer = consume buffer
    let count = min(byteCount - byteOffset, min(maximumCount, buffer.count))
    for index in 0..<count { buffer[index] = bytes[byteOffset + index] }
    return count
  }
}
