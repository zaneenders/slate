/// A stable logical byte snapshot. Sources can overlay bounded edits on a disk
/// file without making the viewport or search know where each byte is stored.
/// An edit invalidates prepared Unicode state by incrementing editRevision.
protocol FileByteSource: ~Copyable {
  var byteCount: Int { get }
  var snapshotIdentity: DocumentFileIdentity { get }
  var editRevision: UInt64 { get }

  borrowing func verifyUnchanged() throws(FileDocumentError)
  mutating func readBytes(
    from byteOffset: Int, maximumCount: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(FileDocumentError) -> Int
  mutating func unicodeCheckpoint(before offset: Int) throws(FileDocumentError) -> FileUnicodeCheckpoint
}

extension FileByteSource where Self: ~Copyable {
  mutating func readBytes(
    from byteOffset: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(FileDocumentError) -> Int {
    try readBytes(from: byteOffset, maximumCount: .max, into: buffer)
  }
}

extension PagedFileDocument: FileByteSource {
  var editRevision: UInt64 { 0 }
}

struct FileByteSnapshot: Equatable {
  let file: DocumentFileIdentity
  let editRevision: UInt64
}
