import SlateUI
import Testing

@Test func documentPreservesUnicodeControlsAndEveryLineEnding() throws {
  for text in ["", "one", "\n", "\r", "\r\n", "a\r\nb\rc\n", "\r\r\n\n", "café\n👩‍💻\r\ne\u{301}\t\0\u{1b}"] {
    let document = try DocumentBuffer(text)
    expectDocument(document, matches: Array(text.utf8))
    #expect(document.isScalarBoundary(at: -1) == false)
    #expect(document.isScalarBoundary(at: document.byteCount + 1) == false)
    #expect(document.lineRange(at: -1) == nil)
    #expect(document.lineRange(at: document.lineCount) == nil)
    #expect(document.lineTerminatorRange(at: document.lineCount) == nil)
    #expect(document.lineIndex(atByteOffset: -1) == nil)
    #expect(document.lineIndex(atByteOffset: document.byteCount + 1) == nil)
  }
}

@Test func documentReplacementHandlesCRLFCreationSplittingAndLineJoining() throws {
  var document = try DocumentBuffer("a\rb", capacity: 32)
  #expect(try document.replace(2..<2, with: "\n".utf8Span) == 2..<3)
  expectDocument(document, matches: Array("a\r\nb".utf8))
  #expect(try document.replace(2..<2, with: "x".utf8Span) == 2..<3)
  expectDocument(document, matches: Array("a\rx\nb".utf8))
  #expect(try document.replace(2..<3, with: "".utf8Span) == 2..<2)
  expectDocument(document, matches: Array("a\r\nb".utf8))
  #expect(try document.replace(1..<3, with: "".utf8Span) == 1..<1)
  expectDocument(document, matches: Array("ab".utf8))
  #expect(try document.replace(0..<2, with: "\r\n".utf8Span) == 0..<2)
  expectDocument(document, matches: Array("\r\n".utf8))
  try document.replace(0..<2, with: "".utf8Span)
  expectDocument(document, matches: [])
}

@Test func documentRejectsInvalidRangesAndSplitScalarsWithoutChangingStorage() throws {
  var document = try DocumentBuffer("é\r\n👩‍💻", capacity: 32)
  let expected = Array(document.snapshot().utf8)
  for range in [-1..<0, 0..<document.byteCount + 1, document.byteCount + 1..<document.byteCount + 1] {
    #expect(throws: DocumentBufferError.invalidRange) { try document.replace(range, with: "x".utf8Span) }
    #expect(throws: DocumentBufferError.invalidRange) { _ = try document.text(in: range) }
    expectDocument(document, matches: expected)
  }
  for range in [1..<1, 0..<1, 5..<6] {
    #expect(throws: DocumentBufferError.invalidUTF8Boundary) { try document.replace(range, with: "x".utf8Span) }
    #expect(throws: DocumentBufferError.invalidUTF8Boundary) { _ = try document.text(in: range) }
    expectDocument(document, matches: expected)
  }
  #expect(String(copying: try document.text(in: 4..<document.byteCount)) == "👩‍💻")
  #expect(try document.text(in: document.byteCount..<document.byteCount).count == 0)
  // Storage accepts scalar-level edits; grapheme policy belongs to the editor.
  try document.replace(0..<2, with: "e\u{301}".utf8Span)
  #expect(document.snapshot() == "e\u{301}\r\n👩‍💻")
  try document.replace(1..<3, with: "".utf8Span)
  #expect(document.snapshot() == "e\r\n👩‍💻")
}

@Test func documentByteAndLineExhaustionAreAtomicAndStorageCanBeReused() throws {
  var document = try DocumentBuffer("a\nb", capacity: 4, lineCapacity: 2)
  let budget = document.storageBudgetBytes
  #expect(throws: DocumentBufferError.capacityExceeded) { try document.replace(0..<0, with: "xx".utf8Span) }
  expectDocument(document, matches: Array("a\nb".utf8))
  #expect(throws: DocumentBufferError.lineCapacityExceeded) { try document.replace(3..<3, with: "\n".utf8Span) }
  expectDocument(document, matches: Array("a\nb".utf8))
  // Replacing selected bytes makes room even when insertion alone would fail.
  try document.replace(0..<3, with: "éé".utf8Span)
  expectDocument(document, matches: Array("éé".utf8))
  try document.replace(0..<4, with: "\r\n".utf8Span)
  expectDocument(document, matches: Array("\r\n".utf8))
  try document.replace(0..<2, with: "x".utf8Span)
  expectDocument(document, matches: [0x78])
  #expect(document.storageBudgetBytes == budget)

  var oneLine = try DocumentBuffer("ab", capacity: 2, lineCapacity: 1)
  #expect(throws: DocumentBufferError.lineCapacityExceeded) { try oneLine.replace(0..<2, with: "\r\n".utf8Span) }
  expectDocument(oneLine, matches: Array("ab".utf8))
}

@Test func documentValidatesStartupBudgetsAndSupportsMaximumWorkload() throws {
  for capacity in [-1, 0, DocumentBuffer.maximumCapacity + 1] {
    #expect(throws: DocumentBufferError.invalidCapacity) { _ = try DocumentBuffer(capacity: capacity) }
  }
  for lines in [-1, 0, 10] {
    #expect(throws: DocumentBufferError.invalidCapacity) { _ = try DocumentBuffer(capacity: 8, lineCapacity: lines) }
  }
  #expect(throws: DocumentBufferError.capacityExceeded) { _ = try DocumentBuffer("abc", capacity: 2) }
  #expect(throws: DocumentBufferError.lineCapacityExceeded) {
    _ = try DocumentBuffer("\n\n", capacity: 8, lineCapacity: 2)
  }
  let capacity = DocumentBuffer.maximumCapacity
  let full = String(repeating: "\n", count: capacity)
  var document = try DocumentBuffer(full, capacity: capacity, lineCapacity: capacity + 1)
  let budget = document.storageBudgetBytes
  #expect(document.byteCount == capacity && document.lineCount == capacity + 1)
  #expect(document.lineRange(at: capacity) == capacity..<capacity)
  #expect(document.lineIndex(atByteOffset: capacity) == capacity)
  #expect(throws: DocumentBufferError.capacityExceeded) { try document.replace(0..<0, with: "x".utf8Span) }
  #expect(document.byteCount == capacity && document.lineCount == capacity + 1)
  try document.replace(0..<capacity, with: "".utf8Span)
  expectDocument(document, matches: [])
  try document.replace(0..<0, with: full.utf8Span)
  #expect(document.byteCount == capacity && document.lineCount == capacity + 1)
  #expect(document.storageBudgetBytes == budget)
}

@Test func documentEditsMatchAnIndependentByteAndLineModelAtCapacityBoundaries() throws {
  var document = try DocumentBuffer(capacity: 32, lineCapacity: 8)
  let budget = document.storageBudgetBytes
  var reference: [UInt8] = []
  let insertions = ["", "x", "\n", "\r", "\r\n", "é", "👩‍💻", "\u{301}", "a\nb", "\0\t\u{1b}"]
  var random: UInt64 = 42
  for _ in 0..<512 {
    // Deterministic test-only LCG; wrapping is intentional.
    random = random &* 6_364_136_223_846_793_005 &+ 1
    let boundaries = (0...reference.count).filter { $0 == reference.count || reference[$0] & 0xc0 != 0x80 }
    let a = boundaries[Int((random >> 16) % UInt64(boundaries.count))]
    let b = boundaries[Int((random >> 32) % UInt64(boundaries.count))]
    let range = min(a, b)..<max(a, b)
    let insertion = insertions[Int((random >> 48) % UInt64(insertions.count))]
    var candidate = reference
    candidate.replaceSubrange(range, with: insertion.utf8)
    if candidate.count > document.capacity {
      #expect(throws: DocumentBufferError.capacityExceeded) { try document.replace(range, with: insertion.utf8Span) }
    } else if referenceLines(candidate).count > document.lineCapacity {
      #expect(throws: DocumentBufferError.lineCapacityExceeded) {
        try document.replace(range, with: insertion.utf8Span)
      }
    } else {
      let insertedRange = try document.replace(range, with: insertion.utf8Span)
      #expect(insertedRange == range.lowerBound..<range.lowerBound + insertion.utf8.count)
      reference = candidate
    }
    expectDocument(document, matches: reference)
    #expect(document.storageBudgetBytes == budget)
  }
}

private func expectDocument(_ document: borrowing DocumentBuffer, matches bytes: [UInt8]) {
  let lines = referenceLines(bytes)
  #expect(document.byteCount == bytes.count)
  #expect(document.snapshot() == String(decoding: bytes, as: UTF8.self))
  #expect(document.lineCount == lines.count)
  do {
    let text = document.text()
    #expect(text.count == bytes.count)
    for index in 0..<text.count { #expect(text.span[index] == bytes[index]) }
  }
  for (index, line) in lines.enumerated() {
    #expect(document.lineRange(at: index) == line.content)
    #expect(document.lineTerminatorRange(at: index) == line.terminator)
  }
  for offset in 0...bytes.count {
    let expectedLine = lines.lastIndex { $0.content.lowerBound <= offset }
    #expect(document.lineIndex(atByteOffset: offset) == expectedLine)
    #expect(document.isScalarBoundary(at: offset) == (offset == bytes.count || bytes[offset] & 0xc0 != 0x80))
  }
}

private func referenceLines(_ bytes: [UInt8]) -> [(content: Range<Int>, terminator: Range<Int>)] {
  var result: [(content: Range<Int>, terminator: Range<Int>)] = []
  var start = 0
  for index in bytes.indices {
    if bytes[index] == 0x0d {
      let end = index + 1 < bytes.count && bytes[index + 1] == 0x0a ? index + 2 : index + 1
      result.append((start..<index, index..<end))
      start = end
    } else if bytes[index] == 0x0a && (index == 0 || bytes[index - 1] != 0x0d) {
      result.append((start..<index, index..<index + 1))
      start = index + 1
    }
  }
  result.append((start..<bytes.count, bytes.count..<bytes.count))
  return result
}
