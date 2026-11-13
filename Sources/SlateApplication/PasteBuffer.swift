import BasicContainers

/// Retains at most `maximumBytes` of the current paste. Capacity starts small,
/// grows on demand, and is retained across resets. Oversized pastes are drained
/// to the terminator and reported once as `.tooLarge`, so their tail never
/// becomes keystrokes. A truncated paste is cancelled at EOF.
struct PasteBuffer: ~Copyable {
  static let defaultMaximumBytes = ScreenApplicationConfiguration.defaultMaximumPasteBytes
  static let maximumSupportedBytes = ScreenApplicationConfiguration.maximumPasteBytesLimit
  static let initialCapacity = 65_536

  let maximumBytes: Int
  private var bytes: UniqueArray<UInt8>
  private(set) var isTooLarge = false

  init(maximumBytes: Int = Self.defaultMaximumBytes) {
    precondition(maximumBytes > 0 && maximumBytes <= Self.maximumSupportedBytes)
    self.maximumBytes = maximumBytes
    bytes = UniqueArray(minimumCapacity: min(Self.initialCapacity, maximumBytes))
  }

  var isEmpty: Bool { bytes.isEmpty }

  mutating func reset() {
    bytes.removeAll()
    isTooLarge = false
  }

  mutating func append(_ byte: UInt8) {
    guard !isTooLarge else { return }
    guard bytes.count < maximumBytes else {
      isTooLarge = true
      return
    }
    bytes.append(byte)
  }

  @_lifetime(borrow self)
  borrowing func text() throws(PasteError) -> UTF8Span {
    precondition(!isTooLarge, "An oversized paste must be rejected before reading its text")
    do { return try UTF8Span(validating: bytes.span) } catch { throw .invalidUTF8 }
  }
}
