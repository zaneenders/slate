/// A UTF-8 document reader, independent of storage, editing, and file I/O policy.
/// Offsets and ranges count UTF-8 bytes. There is always at least one line.
/// A source remains stable throughout one viewport preparation.
public protocol TextDocumentSource: ~Copyable {
  associatedtype ReadError: Error
  var byteCount: Int { get }
  var lineCount: Int { get }

  /// Checks that the indexed snapshot remains valid. Called before and after
  /// viewport preparation; immutable or exclusively borrowed sources need no work.
  mutating func validateSnapshot() throws(ReadError)

  /// Content only, excluding LF, CRLF, or CR. Invalid line indices must throw.
  mutating func lineContentRange(at line: Int) throws(ReadError) -> Range<Int>

  /// Copies at most buffer.count bytes. May stop at an internal page boundary
  /// or split a UTF-8 scalar. Returns zero only at EOF or for an empty buffer.
  /// The buffer cannot be retained. Invalid offsets and I/O failures must throw.
  mutating func readUTF8(
    from byteOffset: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(ReadError) -> Int
}

extension TextDocumentSource where Self: ~Copyable {
  public mutating func validateSnapshot() throws(ReadError) {}
}

extension DocumentBuffer: TextDocumentSource {
  public typealias ReadError = DocumentBufferError

  public borrowing func lineContentRange(at line: Int) throws(DocumentBufferError) -> Range<Int> {
    guard let range = lineRange(at: line) else { throw .invalidRange }
    return range
  }

  public borrowing func readUTF8(
    from byteOffset: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(DocumentBufferError) -> Int {
    guard (0...byteCount).contains(byteOffset) else { throw .invalidRange }
    let text = text().span
    var buffer = consume buffer
    let count = min(buffer.count, byteCount - byteOffset)
    for index in 0..<count { buffer[index] = text[byteOffset + index] }
    return count
  }
}
