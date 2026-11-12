import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func pagedEditsKeepTheOriginalOnDiskAndComposeAllRangeShapes() throws {
  let fixture = try EditFixture(Array("abcdefghij".utf8))
  var buffer = try fixture.buffer(addedByteCapacity: 32, pieceCapacity: 16)
  let budget = buffer.storageBudgetBytes
  #expect(!buffer.isDirty && buffer.addedByteCount == 0 && buffer.pieceCount == 1)
  try buffer.replace(3..<6, with: "漢".utf8Span)
  try buffer.replace(0..<0, with: "START".utf8Span)
  try buffer.replace(buffer.byteCount..<buffer.byteCount, with: "END".utf8Span)
  #expect(try editText(&buffer) == "STARTabc漢ghijEND")
  try buffer.replace(5..<11, with: "é".utf8Span)
  #expect(try editText(&buffer) == "STARTéghijEND")
  try buffer.replace(0..<buffer.byteCount, with: "".utf8Span)
  #expect(buffer.byteCount == 0 && buffer.pieceCount == 0 && buffer.addedByteCount == 0)
  try buffer.replace(0..<0, with: "after deletion".utf8Span)
  #expect(try editText(&buffer) == "after deletion")
  #expect(buffer.pieceCount == 1 && buffer.isDirty && buffer.editRevision == 6)
  #expect(buffer.storageBudgetBytes == budget)
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path)) == Data("abcdefghij".utf8))
}

@Test func pagedEditsCompactRemovedAdditionsAndRejectCapacityAtomically() throws {
  let fixture = try EditFixture(Array("abcdef".utf8))
  var buffer = try fixture.buffer(addedByteCapacity: 4, pieceCapacity: 3)
  let budget = buffer.storageBudgetBytes
  try buffer.replace(3..<3, with: "WXYZ".utf8Span)
  #expect(buffer.addedByteCount == 4 && buffer.pieceCount == 3)
  let revision = buffer.editRevision
  #expect(throws: PagedEditError.addedCapacityExceeded) { try buffer.replace(7..<7, with: "!".utf8Span) }
  #expect(try editText(&buffer) == "abcWXYZdef")
  #expect(buffer.editRevision == revision && buffer.addedByteCount == 4 && buffer.pieceCount == 3)
  try buffer.replace(4..<6, with: "".utf8Span)
  #expect(try editText(&buffer) == "abcWZdef")
  #expect(buffer.addedByteCount == 2 && buffer.pieceCount == 3)
  let beforeFailure = buffer.editRevision
  #expect(throws: PagedEditError.pieceCapacityExceeded) { try buffer.replace(1..<1, with: "Q".utf8Span) }
  #expect(try editText(&buffer) == "abcWZdef")
  #expect(buffer.editRevision == beforeFailure && buffer.addedByteCount == 2 && buffer.pieceCount == 3)
  for _ in 0..<128 {
    try buffer.replace(3..<5, with: "ABCD".utf8Span)
    try buffer.replace(3..<7, with: "XY".utf8Span)
  }
  #expect(try editText(&buffer) == "abcXYdef")
  #expect(buffer.addedByteCount == 2 && buffer.storageBudgetBytes == budget)
  try buffer.replace(3..<5, with: "".utf8Span)
  #expect(buffer.pieceCount == 1 && buffer.addedByteCount == 0)
  #expect(try editText(&buffer) == "abcdef")
}

@Test func pagedEditsMatchDeterministicSplicesIncludingBinaryAndPartialScalars() throws {
  let fixture = try EditFixture([0xff, 0x00, 0xf0, 0x9f, 0x41, 0x1b, 0x42])
  var reference = [UInt8]([0xff, 0x00, 0xf0, 0x9f, 0x41, 0x1b, 0x42])
  var buffer = try fixture.buffer(addedByteCapacity: 1_024, pieceCapacity: 128)
  let replacements = ["", "a", "é", "👩‍💻", "\n\r\n", "hello"]
  var random: UInt64 = 0x9512
  for step in 0..<256 {
    random = random &* 6_364_136_223_846_793_005 &+ 1
    let lower = Int(random % UInt64(reference.count + 1))
    random = random &* 6_364_136_223_846_793_005 &+ 1
    let upper = lower + Int(random % UInt64(reference.count - lower + 1))
    let text = replacements[step % replacements.count]
    try buffer.replace(lower..<upper, with: text.utf8Span)
    reference.replaceSubrange(lower..<upper, with: text.utf8)
    #expect(try editBytes(&buffer) == reference)
    #expect(buffer.byteCount == reference.count && buffer.pieceCount <= 128 && buffer.addedByteCount <= 1_024)
  }
}

@Test func pagedEditDefaultMaximumStorageIsReusableAfterBothExhaustionPaths() throws {
  let fixture = try EditFixture(Array(repeating: 0x61, count: 2_048))
  var pieces = try fixture.buffer(
    addedByteCapacity: 1_048_576, pieceCapacity: 4_096,
    configuration: .init(pageBytes: 4_096, cachePages: 1, maximumPages: 1_024))
  let pieceBudget = pieces.storageBudgetBytes
  for index in 0..<2_048 { try pieces.replace((2 * index + 1)..<(2 * index + 1), with: "X".utf8Span) }
  #expect(pieces.pieceCount == 4_096 && pieces.addedByteCount == 2_048 && pieces.byteCount == 4_096)
  let revision = pieces.editRevision
  #expect(throws: PagedEditError.pieceCapacityExceeded) { try pieces.replace(0..<0, with: "Y".utf8Span) }
  #expect(pieces.editRevision == revision && pieces.storageBudgetBytes == pieceBudget)
  #expect(try editText(&pieces) == String(repeating: "aX", count: 2_048))
  try pieces.replace(0..<pieces.byteCount, with: "".utf8Span)
  let full = String(repeating: "z", count: 1_048_576)
  try pieces.replace(0..<0, with: full.utf8Span)
  #expect(pieces.pieceCount == 1 && pieces.addedByteCount == 1_048_576)
  let fullRevision = pieces.editRevision
  #expect(throws: PagedEditError.addedCapacityExceeded) {
    try pieces.replace(pieces.byteCount..<pieces.byteCount, with: "!".utf8Span)
  }
  #expect(pieces.editRevision == fullRevision && pieces.storageBudgetBytes == pieceBudget)
  try pieces.replace(0..<1, with: "A".utf8Span)
  #expect(pieces.addedByteCount == 1_048_576 && pieces.pieceCount == 1)
  #expect(try pieces.byte(at: 0) == 0x41 && pieces.byte(at: 1_048_575) == 0x7a)
  #expect(pieces.storageBudgetBytes == pieceBudget)
}

@Test func pagedEditReadLimitsBoundsAndFileCapacityPreserveState() throws {
  let fixture = try EditFixture(Array("abcdefgh".utf8))
  var buffer = try fixture.buffer(
    addedByteCapacity: 16, pieceCapacity: 16,
    configuration: .init(pageBytes: 4, cachePages: 1, maximumPages: 2))
  #expect(throws: PagedEditError.fileCapacityExceeded) { try buffer.replace(8..<8, with: "x".utf8Span) }
  #expect(throws: PagedEditError.invalidRange) { try buffer.replace(-1..<0, with: "x".utf8Span) }
  #expect(throws: PagedEditError.invalidRange) { try buffer.replace(8..<9, with: "".utf8Span) }
  #expect(!buffer.isDirty && buffer.editRevision == 0)
  try buffer.replace(2..<4, with: "XY".utf8Span)
  var bytes = InlineArray<8, UInt8>(repeating: 0xa5)
  #expect(try buffer.readBytes(from: 0, into: bytes.mutableSpan) == 2)
  #expect(bytes[0] == 0x61 && bytes[1] == 0x62 && bytes[2] == 0xa5)
  bytes = .init(repeating: 0xa5)
  #expect(try buffer.readBytes(from: 2, maximumCount: 1, into: bytes.mutableSpan) == 1)
  #expect(bytes[0] == 0x58 && bytes[1] == 0xa5)
  #expect(try buffer.readBytes(from: 8, into: bytes.mutableSpan) == 0)
  #expect(try buffer.readBytes(from: 0, maximumCount: 0, into: bytes.mutableSpan) == 0)
  #expect(throws: FileDocumentError.invalidRange) {
    try buffer.readBytes(from: 0, maximumCount: -1, into: bytes.mutableSpan)
  }
  #expect(throws: FileDocumentError.invalidRange) { try buffer.readBytes(from: 9, into: bytes.mutableSpan) }
  #expect(try buffer.byte(at: 2) == 0x58)
  #expect(throws: FileDocumentError.invalidRange) { try buffer.byte(at: 8) }
  #expect(try editText(&buffer) == "abXYefgh")
}

@Test func pagedEditsSeekFarFromAnEditWithoutLoadingTheInterveningFile() throws {
  let fixture = try EditFixture(Array(repeating: 0x37, count: 2_097_152))
  var buffer = try fixture.buffer(
    addedByteCapacity: 32, pieceCapacity: 8,
    configuration: .init(pageBytes: 4_096, cachePages: 1, maximumPages: 1_024))
  #expect(buffer.residentPageCount == 0)
  try buffer.replace(3..<3, with: "INSERT".utf8Span)
  #expect(buffer.statistics.loads == 0 && buffer.addedByteCount == 6)
  let budget = buffer.storageBudgetBytes
  let checkpoint = try buffer.unicodeCheckpoint(before: 2_000_000)
  #expect(checkpoint.offset == 1_999_999)
  #expect(buffer.statistics.bytesRead <= 8_192 && buffer.residentPageCount == 1)
  var viewport = try FileByteViewport(maximumSize: .init(columns: 16, rows: 2))
  try viewport.prepare(from: &buffer, firstByte: 2_000_000, size: viewport.maximumSize)
  #expect(viewport.visibleRange == 2_000_000..<2_000_032)
  #expect(viewport.byte(at: 0) == 0x37 && buffer.statistics.bytesRead < 32_768)
  #expect(buffer.storageBudgetBytes == budget)
}

@Test func pagedEditCheckpointsPreserveContextAcrossUnicodeSplicesAndRevisionChanges() throws {
  for original in ["A👩‍💻e\u{301}Z", "🇦🇧🇨🇩🇪🇫🇬🇭", "\u{600}漢漢漢", "x\r\ny"] {
    let fixture = try EditFixture(Array(original.utf8))
    var buffer = try fixture.buffer(addedByteCapacity: 128, pieceCapacity: 16)
    try buffer.replace(0..<0, with: "\u{600}".utf8Span)
    let expected = "\u{600}" + original
    let referenceFixture = try EditFixture(Array(expected.utf8))
    var reference = try PagedFileDocument.open(
      referenceFixture.path, configuration: .init(pageBytes: 4, cachePages: 1), content: .bytes)
    var actualView = try FileByteViewport(maximumSize: .init(columns: 8, rows: 2))
    var expectedView = try FileByteViewport(maximumSize: .init(columns: 8, rows: 2))
    for offset in 0..<buffer.byteCount {
      try actualView.prepare(from: &buffer, firstByte: offset, size: actualView.maximumSize)
      try expectedView.prepare(from: &reference, firstByte: offset, size: expectedView.maximumSize)
      #expect(actualView.visibleRange == expectedView.visibleRange)
      for row in 0..<2 {
        for column in 0..<8 {
          #expect(
            actualView.byteRange(column: column, row: row, clamp: false)
              == expectedView.byteRange(column: column, row: row, clamp: false))
        }
      }
    }
  }
}

@Test func pagedEditsDetectOriginalMutationAndRebaseWithoutGrowingOverlayStorage() throws {
  let fixture = try EditFixture(Array("original".utf8))
  var buffer = try fixture.buffer(addedByteCapacity: 16, pieceCapacity: 8)
  try buffer.replace(0..<0, with: "new ".utf8Span)
  let budget = buffer.storageBudgetBytes
  let oldIdentity = buffer.snapshotIdentity
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
  try handle.truncate(atOffset: 2)
  try handle.close()
  #expect(throws: PagedEditError.source(.fileChanged)) { try buffer.replace(0..<0, with: "!".utf8Span) }
  #expect(buffer.byteCount == 12 && buffer.addedByteCount == 4 && buffer.editRevision == 1)
  let replacement = try EditFixture(Array("saved replacement".utf8))
  let source = try PagedFileDocument.open(
    replacement.path, configuration: .init(pageBytes: 4, cachePages: 1), content: .bytes)
  buffer.replaceBase(source)
  #expect(!buffer.isDirty && buffer.addedByteCount == 0 && buffer.pieceCount == 1 && buffer.editRevision == 0)
  #expect(buffer.snapshotIdentity != oldIdentity && buffer.storageBudgetBytes == budget)
  #expect(try editText(&buffer) == "saved replacement")
  try buffer.replace(0..<5, with: "fresh".utf8Span)
  #expect(try editText(&buffer) == "fresh replacement")
}

private func editText(_ buffer: inout PagedEditBuffer) throws -> String {
  String(decoding: try editBytes(&buffer), as: UTF8.self)
}

private func editBytes(_ buffer: inout PagedEditBuffer) throws -> [UInt8] {
  var bytes = [UInt8]()
  var output = InlineArray<7, UInt8>(repeating: 0)
  while bytes.count < buffer.byteCount {
    let count = try buffer.readBytes(from: bytes.count, into: output.mutableSpan)
    try #require(count > 0)
    for index in 0..<count { bytes.append(output[index]) }
  }
  return bytes
}

private struct EditFixture: ~Copyable {
  let path: String

  init(_ bytes: [UInt8]) throws {
    path = NSTemporaryDirectory() + "slate-edits-" + UUID().uuidString
    try Data(bytes).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }

  borrowing func buffer(
    addedByteCapacity: Int, pieceCapacity: Int,
    configuration: FileDocumentConfiguration = .init(pageBytes: 4, cachePages: 1)
  ) throws -> PagedEditBuffer {
    try PagedEditBuffer(
      source: PagedFileDocument.open(path, configuration: configuration, content: .bytes),
      addedByteCapacity: addedByteCapacity, pieceCapacity: pieceCapacity)
  }

  deinit { try? FileManager.default.removeItem(atPath: path) }
}
