import BasicContainers
import SlateTerminal

/// One startup allocation. Overflow discards the entire paste through its end
/// marker; a truncated paste is cancelled at EOF, never replayed as keystrokes.
struct PasteBuffer: ~Copyable {
  static let capacity = 65_536
  private var bytes = RigidArray(repeating: UInt8(0), count: capacity)
  private var count = 0
  private var overflow = false

  mutating func reset() {
    count = 0
    overflow = false
  }

  mutating func append(_ byte: UInt8) {
    guard count < bytes.count else {
      overflow = true
      return
    }
    bytes[count] = byte
    count += 1
  }

  @_lifetime(borrow self)
  borrowing func text() throws(PasteError) -> UTF8Span {
    guard !overflow else { throw .capacityExceeded }
    do { return try UTF8Span(validating: bytes.span.extracting(first: count)) } catch { throw .invalidUTF8 }
  }
}
