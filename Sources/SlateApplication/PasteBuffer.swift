import BasicContainers
import SlateTerminal

/// Reserves 65,536 bytes at startup and grows with incoming paste bytes.
/// Capacity is retained across resets. A truncated paste is cancelled at EOF,
/// never replayed as keystrokes.
struct PasteBuffer: ~Copyable {
  private var bytes = UniqueArray<UInt8>(minimumCapacity: 65_536)

  mutating func reset() {
    bytes.removeAll()
  }

  mutating func append(_ byte: UInt8) {
    bytes.append(byte)
  }

  @_lifetime(borrow self)
  borrowing func text() throws(PasteError) -> UTF8Span {
    do { return try UTF8Span(validating: bytes.span) } catch { throw .invalidUTF8 }
  }
}
