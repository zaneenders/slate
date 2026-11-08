import BasicContainers

public enum DocumentBufferError: Error, Equatable, Sendable {
  case invalidCapacity
  case invalidRange
  case invalidUTF8Boundary
  case capacityExceeded
  case lineCapacityExceeded
}

/// Bounded UTF-8 document storage, independent of cursor, selection, commands,
/// history, and rendering. Byte offsets are the public coordinate system.
///
/// Allocates two byte buffers and one UInt32 line index during initialization.
/// Reads and edits reuse that storage without growth or steady-state allocation.
/// Replacement stages the entire result before committing; rejection preserves
/// both text and line metadata. First-use runtime metadata, snapshots, and
/// caller-owned input are outside this guarantee.
///
/// LF, CRLF, and CR each terminate a line; original bytes are preserved. There is
/// always at least one line, including an empty final line after a terminator.
/// Edits require Unicode scalar boundaries. Applications choose grapheme-level
/// editing policy using the borrowed text's character iterator.
public struct DocumentBuffer: ~Copyable, ~Sendable {
  public static let maximumCapacity = 1_048_576
  public let capacity: Int
  public let lineCapacity: Int
  public private(set) var byteCount: Int
  public private(set) var lineCount: Int
  private var bytes: RigidArray<UInt8>
  private var scratch: RigidArray<UInt8>
  private var lineStarts: RigidArray<UInt32>

  /// Defaults to 64 KiB and up to 4,096 lines. Explicit line capacity may be
  /// anywhere from one to capacity + 1 (the all-newline worst case).
  public init(
    _ text: String = "", capacity: Int = 65_536, lineCapacity: Int? = nil
  ) throws(DocumentBufferError) {
    guard (1...Self.maximumCapacity).contains(capacity) else { throw .invalidCapacity }
    let lineCapacity = lineCapacity ?? min(4_096, capacity + 1)
    guard (1...(capacity + 1)).contains(lineCapacity) else { throw .invalidCapacity }
    var document = Self(storageCapacity: capacity, lineCapacity: lineCapacity)
    try document.replace(0..<0, with: text.utf8Span)
    self = consume document
  }

  private init(storageCapacity capacity: Int, lineCapacity: Int) {
    self.capacity = capacity
    self.lineCapacity = lineCapacity
    byteCount = 0
    lineCount = 1
    bytes = RigidArray(repeating: 0, count: capacity)
    scratch = RigidArray(repeating: 0, count: capacity)
    lineStarts = RigidArray(repeating: 0, count: lineCapacity)
  }

  /// Owned storage including the inline owner; excludes allocator metadata.
  public var storageBudgetBytes: Int {
    2 * capacity + lineCapacity * MemoryLayout<UInt32>.stride + MemoryLayout<Self>.stride
  }

  /// The view cannot outlive its owner or overlap an edit. No String is made.
  @_lifetime(borrow self)
  public borrowing func text() -> UTF8Span {
    // All input is already valid UTF-8, and edits never split a scalar.
    unsafe UTF8Span(unchecked: bytes.span.extracting(first: byteCount))
  }

  /// A validated borrowed slice, for example a line or a highlighting run.
  @_lifetime(borrow self)
  public borrowing func text(in range: Range<Int>) throws(DocumentBufferError) -> UTF8Span {
    try validate(range)
    return unsafe UTF8Span(unchecked: bytes.span.extracting(range))
  }

  /// Explicitly allocating snapshot for file I/O or other work outside the loop.
  public borrowing func snapshot() -> String { String(copying: text()) }

  public borrowing func isScalarBoundary(at byteOffset: Int) -> Bool {
    guard (0...byteCount).contains(byteOffset) else { return false }
    return byteOffset == byteCount || bytes[byteOffset] & 0xc0 != 0x80
  }

  /// Content only: excludes this line's CR, LF, or CRLF terminator.
  public borrowing func lineRange(at index: Int) -> Range<Int>? {
    guard (0..<lineCount).contains(index) else { return nil }
    let start = Int(lineStarts[index])
    var end = index + 1 < lineCount ? Int(lineStarts[index + 1]) : byteCount
    if end > start && bytes[end - 1] == 0x0a { end -= 1 }
    if end > start && bytes[end - 1] == 0x0d { end -= 1 }
    return start..<end
  }

  /// The exact terminator bytes, or an empty range for the final line.
  public borrowing func lineTerminatorRange(at index: Int) -> Range<Int>? {
    guard let content = lineRange(at: index) else { return nil }
    let end = index + 1 < lineCount ? Int(lineStarts[index + 1]) : byteCount
    return content.upperBound..<end
  }

  /// O(log lineCount). Terminator bytes belong to their preceding line; EOF
  /// belongs to the final line. Returns nil for offsets outside the document.
  public borrowing func lineIndex(atByteOffset byteOffset: Int) -> Int? {
    guard (0...byteCount).contains(byteOffset) else { return nil }
    var lower = 0
    var upper = lineCount
    while lower + 1 < upper {
      let middle = lower + (upper - lower) / 2
      if Int(lineStarts[middle]) <= byteOffset { lower = middle } else { upper = middle }
    }
    return lower
  }

  /// O(old byteCount + inserted bytes), bounded by maximumCapacity. A contiguous
  /// staging buffer favors simple, atomic edits for small documents over a more
  /// complex piece tree. No edit history or cursor policy is retained.
  ///
  /// Returns the inserted range in the new document, including an empty range
  /// for deletion. Input may contain any valid UTF-8, including control scalars;
  /// presentation is responsible for terminal-control sanitization.
  @discardableResult
  public mutating func replace(
    _ range: Range<Int>, with text: UTF8Span
  ) throws(DocumentBufferError) -> Range<Int> {
    try validate(range)
    guard text.count <= capacity - (byteCount - range.count) else { throw .capacityExceeded }
    let source = text.span
    let insertedEnd = range.lowerBound + source.count
    let newCount = byteCount - range.count + source.count
    for index in 0..<range.lowerBound { scratch[index] = bytes[index] }
    for index in 0..<source.count { scratch[range.lowerBound + index] = source[index] }
    for index in range.upperBound..<byteCount {
      scratch[insertedEnd + index - range.upperBound] = bytes[index]
    }

    // Count before touching live line metadata. Splicing can create or split a
    // CRLF pair at either boundary, so inspect the staged result as a whole.
    var newLineCount = 1
    var index = 0
    while index < newCount {
      let byte = scratch[index]
      index += 1
      if byte == 0x0d || byte == 0x0a {
        if byte == 0x0d && index < newCount && scratch[index] == 0x0a { index += 1 }
        guard newLineCount < lineCapacity else { throw .lineCapacityExceeded }
        newLineCount += 1
      }
    }

    swap(&bytes, &scratch)
    byteCount = newCount
    lineCount = newLineCount
    lineStarts[0] = 0
    var line = 1
    index = 0
    while index < byteCount {
      let byte = bytes[index]
      index += 1
      if byte == 0x0d || byte == 0x0a {
        if byte == 0x0d && index < byteCount && bytes[index] == 0x0a { index += 1 }
        lineStarts[line] = UInt32(index)
        line += 1
      }
    }
    assert(line == lineCount)
    return range.lowerBound..<insertedEnd
  }

  private borrowing func validate(_ range: Range<Int>) throws(DocumentBufferError) {
    guard range.lowerBound >= 0 && range.upperBound <= byteCount else { throw .invalidRange }
    guard isScalarBoundary(at: range.lowerBound) && isScalarBoundary(at: range.upperBound) else {
      throw .invalidUTF8Boundary
    }
  }
}
