import BasicContainers
import Slate

enum PagedEditError: Error, Equatable, Sendable {
  case invalidRange
  case addedCapacityExceeded
  case pieceCapacityExceeded
  case fileCapacityExceeded
  case revisionCapacityExceeded
  case source(FileDocumentError)
}

/// A fixed-capacity piece table over a paged, immutable file snapshot. Original
/// bytes stay on disk; only inserted bytes and range descriptors are resident.
/// The default overlay payload is 2 MiB of added-byte storage plus two 4,096
/// element piece tables (256 KiB on 64-bit hosts) and 4 KiB of checkpoint scratch.
/// File cache/index storage is accounted for separately by the underlying reader.
///
/// An edit stages both the table and compacted surviving additions before
/// committing. Capacity failures preserve the complete previous document.
/// Each edit scans at most twice the piece capacity and copies at most the added
/// byte capacity; it never copies unchanged file bytes. Successful edits/reads
/// allocate no storage after initialization. Swift error boxes/runtime warm-up
/// and the explicitly requested save/reindex lifecycle are outside that promise.
///
/// Byte ranges deliberately permit binary/malformed input to remain untouched.
/// The UI selects complete displayed grapheme ranges; inserted text is UTF-8.
struct PagedEditBuffer: FileByteSource, ~Copyable, ~Sendable {
  // Internal visibility avoids a Swift 6.4 debug metadata linkage failure when
  // this noncopyable owner's rigid storage is embedded in the viewer class.
  struct Piece {
    var documentOffset = 0
    var sourceOffset = 0
    var count = 0
    var added = false
  }

  let addedByteCapacity: Int
  let pieceCapacity: Int
  private var source: PagedFileDocument
  private var pieces: RigidArray<Piece>
  private var stagedPieces: RigidArray<Piece>
  private var addedBytes: RigidArray<UInt8>
  private var stagedBytes: RigidArray<UInt8>
  private var checkpointBytes = InlineArray<4_096, UInt8>(repeating: 0)
  private var firstChangedByte: Int?
  private(set) var byteCount: Int
  private(set) var pieceCount: Int
  private(set) var addedByteCount = 0
  private(set) var editRevision: UInt64 = 0
  private(set) var isDirty = false

  init(
    source: consuming PagedFileDocument,
    addedByteCapacity: Int = 1_048_576, pieceCapacity: Int = 4_096
  ) throws(FileDocumentError) {
    guard (1...16_777_216).contains(addedByteCapacity), (1...65_536).contains(pieceCapacity) else {
      throw .invalidConfiguration
    }
    self.addedByteCapacity = addedByteCapacity
    self.pieceCapacity = pieceCapacity
    byteCount = source.byteCount
    pieceCount = byteCount == 0 ? 0 : 1
    self.source = consume source
    pieces = RigidArray(repeating: Piece(), count: pieceCapacity)
    stagedPieces = RigidArray(repeating: Piece(), count: pieceCapacity)
    addedBytes = RigidArray(repeating: 0, count: addedByteCapacity)
    stagedBytes = RigidArray(repeating: 0, count: addedByteCapacity)
    if byteCount > 0 { pieces[0] = Piece(count: byteCount) }
  }

  var revision: UInt64 { editRevision }
  var configuration: FileDocumentConfiguration { source.configuration }
  var snapshotIdentity: DocumentFileIdentity { source.snapshotIdentity }
  var statistics: FilePageStatistics { source.statistics }
  var indexedPageCount: Int { source.indexedPageCount }
  var residentPageCount: Int { source.residentPageCount }
  var cacheStorageBudgetBytes: Int { source.cacheStorageBudgetBytes }
  var indexMetadataAllowanceBytes: Int { source.indexMetadataAllowanceBytes }
  var storageBudgetBytes: Int {
    source.cacheStorageBudgetBytes + 2 * addedByteCapacity
      + 2 * pieceCapacity * MemoryLayout<Piece>.stride + MemoryLayout<Self>.stride
  }

  borrowing func cachedPageNumber(at slot: Int) -> Int? { source.cachedPageNumber(at: slot) }
  borrowing func verifyUnchanged() throws(FileDocumentError) { try source.verifyUnchanged() }
  mutating func discardCachedPages() { source.discardCachedPages() }

  /// Installs a successfully written and reindexed file without reallocating the
  /// overlay. The caller excludes edits/borrows while saving and indexing.
  mutating func replaceBase(_ replacement: consuming PagedFileDocument) {
    source = consume replacement
    byteCount = source.byteCount
    pieceCount = byteCount == 0 ? 0 : 1
    if byteCount > 0 { pieces[0] = Piece(count: byteCount) }
    addedByteCount = 0
    firstChangedByte = nil
    isDirty = false
    // Revisions are scoped to the base file identity. A save publishes a new
    // identity; reinstalling the same unchanged base also safely discards all
    // edits because its previous nonzero edit revision becomes zero.
    editRevision = 0
  }

  /// Reads one piece and at most one original disk page. No retained borrow or
  /// pointer spans a call, and the unused tail of the destination is unchanged.
  mutating func readBytes(
    from byteOffset: Int, maximumCount: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(FileDocumentError) -> Int {
    guard (0...byteCount).contains(byteOffset), maximumCount >= 0 else { throw .invalidRange }
    guard byteOffset < byteCount, maximumCount > 0, !buffer.isEmpty else { return 0 }
    let piece = pieces[pieceIndex(at: byteOffset)]
    let local = byteOffset - piece.documentOffset
    let requested = min(maximumCount, min(buffer.count, piece.count - local))
    if !piece.added {
      return try source.readBytes(from: piece.sourceOffset + local, maximumCount: requested, into: buffer)
    }
    var buffer = consume buffer
    for index in 0..<requested { buffer[index] = addedBytes[piece.sourceOffset + local + index] }
    return requested
  }

  mutating func byte(at offset: Int) throws(FileDocumentError) -> UInt8 {
    guard (0..<byteCount).contains(offset) else { throw .invalidRange }
    var output = InlineArray<1, UInt8>(repeating: 0)
    let count = try readBytes(from: offset, maximumCount: 1, into: output.mutableSpan)
    precondition(count == 1)
    return output[0]
  }

  /// An original page checkpoint can have grapheme context invalidated by an
  /// earlier edit. Search at most 4 KiB for a proven reset: two ASCII scalars,
  /// other than CRLF, always break before the second. The common ASCII-file seek
  /// remains local even after edits near the beginning of a multi-gigabyte file.
  /// Pathological Unicode without such a reset replays cooperatively from the
  /// original checkpoint before the earliest edit; correctness wins over a false
  /// boundary. The viewport bounds replay work per event-loop turn.
  mutating func unicodeCheckpoint(before offset: Int) throws(FileDocumentError) -> FileUnicodeCheckpoint {
    precondition((0...byteCount).contains(offset))
    guard let firstChangedByte, offset > firstChangedByte else {
      return source.unicodeCheckpoint(before: offset)
    }
    let start = max(0, offset - checkpointBytes.count)
    let requested = offset - start
    var copied = 0
    while copied < requested {
      // readBytes mutates the same owner, so use a bounded independent staging
      // block and copy it into owner storage after the source borrow has ended.
      var block = InlineArray<256, UInt8>(repeating: 0)
      let count = try readBytes(
        from: start + copied, maximumCount: min(block.count, requested - copied), into: block.mutableSpan)
      guard count > 0 else { throw .fileChanged }
      for index in 0..<count { checkpointBytes[copied + index] = block[index] }
      copied += count
    }
    if copied > 1 {
      for index in stride(from: copied - 1, through: 1, by: -1) {
        let previous = checkpointBytes[index - 1]
        let current = checkpointBytes[index]
        if previous < 0x80 && current < 0x80 && !(previous == 13 && current == 10) {
          return .init(offset: start + index)
        }
      }
    }
    return source.unicodeCheckpoint(before: firstChangedByte)
  }

  @discardableResult
  mutating func replace(_ range: Range<Int>, with text: UTF8Span) throws(PagedEditError) -> Range<Int> {
    guard range.lowerBound >= 0, range.upperBound <= byteCount else { throw .invalidRange }
    guard !range.isEmpty || !text.isEmpty else { return range }
    guard editRevision < .max else { throw .revisionCapacityExceeded }
    let retainedBytes = byteCount - range.count
    guard text.count <= configuration.maximumFileBytes - retainedBytes else { throw .fileCapacityExceeded }
    var survivingAddedBytes = addedByteCount
    for index in 0..<pieceCount where pieces[index].added {
      let piece = pieces[index]
      let removed = max(
        0, min(range.upperBound, piece.documentOffset + piece.count) - max(range.lowerBound, piece.documentOffset))
      survivingAddedBytes -= removed
    }
    guard text.count <= addedByteCapacity - survivingAddedBytes else { throw .addedCapacityExceeded }
    do throws(FileDocumentError) { try source.verifyUnchanged() } catch { throw .source(error) }

    var stagedPieceCount = 0
    var stagedByteCount = 0
    var stagedDocumentBytes = 0
    try stage(
      range: 0..<range.lowerBound, pieces: &stagedPieceCount,
      bytes: &stagedByteCount, documentBytes: &stagedDocumentBytes)
    if !text.isEmpty {
      let source = text.span
      let start = stagedByteCount
      for index in 0..<source.count { stagedBytes[start + index] = source[index] }
      stagedByteCount += source.count
      try appendStaged(
        Piece(sourceOffset: start, count: source.count, added: true),
        pieces: &stagedPieceCount, documentBytes: &stagedDocumentBytes)
    }
    try stage(
      range: range.upperBound..<byteCount, pieces: &stagedPieceCount,
      bytes: &stagedByteCount, documentBytes: &stagedDocumentBytes)
    assert(stagedDocumentBytes == retainedBytes + text.count)
    assert(stagedByteCount == survivingAddedBytes + text.count)
    swap(&pieces, &stagedPieces)
    swap(&addedBytes, &stagedBytes)
    pieceCount = stagedPieceCount
    addedByteCount = stagedByteCount
    byteCount = stagedDocumentBytes
    firstChangedByte = min(firstChangedByte ?? range.lowerBound, range.lowerBound)
    isDirty = true
    editRevision += 1
    return range.lowerBound..<range.lowerBound + text.count
  }

  private borrowing func pieceIndex(at offset: Int) -> Int {
    precondition((0..<byteCount).contains(offset) && pieceCount > 0)
    var lower = 0
    var upper = pieceCount
    while lower + 1 < upper {
      let middle = lower + (upper - lower) / 2
      if pieces[middle].documentOffset <= offset { lower = middle } else { upper = middle }
    }
    return lower
  }

  private mutating func stage(
    range: Range<Int>, pieces count: inout Int, bytes byteCount: inout Int, documentBytes: inout Int
  ) throws(PagedEditError) {
    for index in 0..<pieceCount {
      let piece = pieces[index]
      let start = max(range.lowerBound, piece.documentOffset)
      let end = min(range.upperBound, piece.documentOffset + piece.count)
      guard start < end else { continue }
      let sourceOffset = piece.sourceOffset + start - piece.documentOffset
      let length = end - start
      if piece.added {
        let destination = byteCount
        for byte in 0..<length { stagedBytes[destination + byte] = addedBytes[sourceOffset + byte] }
        byteCount += length
        try appendStaged(
          Piece(sourceOffset: destination, count: length, added: true), pieces: &count, documentBytes: &documentBytes)
      } else {
        try appendStaged(
          Piece(sourceOffset: sourceOffset, count: length), pieces: &count, documentBytes: &documentBytes)
      }
    }
  }

  private mutating func appendStaged(
    _ piece: Piece, pieces count: inout Int, documentBytes: inout Int
  ) throws(PagedEditError) {
    precondition(piece.count > 0)
    if count > 0 {
      let previous = stagedPieces[count - 1]
      if previous.added == piece.added && previous.sourceOffset + previous.count == piece.sourceOffset {
        stagedPieces[count - 1].count += piece.count
        documentBytes += piece.count
        return
      }
    }
    guard count < pieceCapacity else { throw .pieceCapacityExceeded }
    var piece = piece
    piece.documentOffset = documentBytes
    stagedPieces[count] = piece
    count += 1
    documentBytes += piece.count
  }
}
