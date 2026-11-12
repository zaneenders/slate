import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

#if canImport(Darwin)
import Darwin
#endif

/// Opt-in because this scans and writes a gigabyte. Run in release mode:
/// SLATE_RUN_LARGE_FILE_TESTS=1 swift test -c release --filter largeDocumentWrite
/// SLATE_LARGE_DOCUMENT_PATH optionally selects a different >= 1 GB fixture.
/// The original is only opened for reading; all edits target a temporary copy.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_RUN_LARGE_FILE_TESTS"] == "1"))
func largeDocumentWriteStreamsAGigabyteAndPreservesEveryUneditedByte() throws {
  let defaultFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("pi_hex_1b.txt")
  let originalURL =
    ProcessInfo.processInfo.environment["SLATE_LARGE_DOCUMENT_PATH"].map { URL(fileURLWithPath: $0) }
    ?? defaultFixture
  let original = try OwnedDocumentFile.open(originalURL.path)
  let originalIdentity = try original.identity()
  try #require(originalIdentity.byteCount >= 1_000_000_000)
  let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "slate-gigabyte-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let editedURL = directory.appendingPathComponent("edited-file")
  #if canImport(Darwin)
  let heapBefore = largeWriteHeapStatistics()
  let rssBefore = largeWriteMaximumResidentBytes()
  #endif
  try FileManager.default.copyItem(at: originalURL, to: editedURL)
  let paged = try PagedFileDocument.open(editedURL.path, content: .bytes)
  var buffer = try PagedEditBuffer(source: paged)
  let storageBudget = buffer.storageBudgetBytes
  let middle = originalIdentity.byteCount / 2
  let prefix = "<start>"
  let replacement = "<mid>"
  let suffix = "<end>"
  try buffer.replace(0..<0, with: prefix.utf8Span)
  try buffer.replace((prefix.utf8.count + middle)..<(prefix.utf8.count + middle + 4), with: replacement.utf8Span)
  try buffer.replace(buffer.byteCount..<buffer.byteCount, with: suffix.utf8Span)
  #expect(buffer.storageBudgetBytes == storageBudget)
  #expect(storageBudget < 16_777_216)
  let expectedBytes = originalIdentity.byteCount + prefix.utf8.count + replacement.utf8.count - 4 + suffix.utf8.count
  #expect(buffer.byteCount == expectedBytes)
  let savedIdentity: DocumentFileIdentity
  do {
    var writer = try DocumentFileWrite(
      editedURL.path, expectedIdentity: buffer.snapshotIdentity, expectedByteCount: buffer.byteCount)
    var scratch = InlineArray<65_536, UInt8>(repeating: 0)
    var offset = 0
    var turns = 0
    let maximumTurns = (expectedBytes + scratch.count - 1) / scratch.count + buffer.pieceCapacity
    while offset < buffer.byteCount && turns < maximumTurns {
      let count = try buffer.readBytes(from: offset, into: scratch.mutableSpan)
      guard count > 0 else {
        Issue.record("Streaming save failed to advance")
        return
      }
      try writer.append(scratch.span.extracting(first: count))
      offset += count
      turns += 1
    }
    try #require(offset == expectedBytes)
    try buffer.verifyUnchanged()
    savedIdentity = try writer.commit()
    #expect(writer.bytesWritten == expectedBytes)
  }
  #expect(buffer.storageBudgetBytes == storageBudget)
  let saved = try OwnedDocumentFile.open(editedURL.path)
  #expect(try saved.identity() == savedIdentity)
  #expect(savedIdentity.byteCount == expectedBytes)
  try largeWriteExpectText(prefix, in: saved, at: 0)
  try largeWriteCompare(original, from: 0, saved, from: prefix.utf8.count, count: middle)
  try largeWriteExpectText(replacement, in: saved, at: prefix.utf8.count + middle)
  try largeWriteCompare(
    original, from: middle + 4, saved, from: prefix.utf8.count + middle + replacement.utf8.count,
    count: originalIdentity.byteCount - middle - 4)
  try largeWriteExpectText(suffix, in: saved, at: expectedBytes - suffix.utf8.count)
  #expect(try original.identity() == originalIdentity)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["edited-file"])
  #if canImport(Darwin)
  let heapAfter = largeWriteHeapStatistics()
  let rssAfter = largeWriteMaximumResidentBytes()
  // This checks retained heap and peak RSS, not allocation-call counts.
  // The cap catches a whole-document snapshot while allowing runtime metadata,
  // the bounded rope index, cache/overlay initialization, and test machinery.
  #expect(heapAfter.size_in_use <= heapBefore.size_in_use + 134_217_728)
  #expect(rssAfter <= rssBefore + 134_217_728)
  print(
    "1 GB streamed save: owned payload \(storageBudget) bytes; live heap \(heapAfter.size_in_use) bytes; "
      + "RSS high-water \(rssAfter) bytes; verified \(expectedBytes) output bytes")
  #endif
}

private func largeWriteCompare(
  _ original: borrowing OwnedDocumentFile, from originalOffset: Int,
  _ saved: borrowing OwnedDocumentFile, from savedOffset: Int, count: Int
) throws {
  var expected = InlineArray<65_536, UInt8>(repeating: 0)
  var actual = InlineArray<65_536, UInt8>(repeating: 0)
  var compared = 0
  while compared < count {
    let length = min(expected.count, count - compared)
    do {
      var storage = expected.mutableSpan
      try original.readExactly(from: originalOffset + compared, into: storage._mutatingExtracting(first: length))
    }
    do {
      var storage = actual.mutableSpan
      try saved.readExactly(from: savedOffset + compared, into: storage._mutatingExtracting(first: length))
    }
    for index in 0..<length where expected[index] != actual[index] {
      Issue.record("Saved bytes differ in unchanged region at output offset \(savedOffset + compared + index)")
      return
    }
    compared += length
  }
}

private func largeWriteExpectText(_ text: String, in file: borrowing OwnedDocumentFile, at offset: Int) throws {
  var bytes = InlineArray<64, UInt8>(repeating: 0)
  precondition(text.utf8.count <= bytes.count)
  do {
    var storage = bytes.mutableSpan
    try file.readExactly(from: offset, into: storage._mutatingExtracting(first: text.utf8.count))
  }
  for index in 0..<text.utf8.count { #expect(bytes[index] == text.utf8Span.span[index]) }
}

#if canImport(Darwin)
private func largeWriteHeapStatistics() -> malloc_statistics_t {
  var statistics = malloc_statistics_t()
  malloc_zone_statistics(nil, &statistics)
  return statistics
}

private func largeWriteMaximumResidentBytes() -> Int {
  var usage = rusage()
  precondition(getrusage(RUSAGE_SELF, &usage) == 0)
  return usage.ru_maxrss
}
#endif
