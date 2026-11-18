import BasicContainers

//// Fixed startup paste storage. Oversized payloads are drained and rejected once.
struct PasteBuffer: ~Copyable {
  static let defaultMaximumBytes = ScreenApplicationConfiguration.defaultMaximumPasteBytes
  static let maximumSupportedBytes = ScreenApplicationConfiguration.maximumPasteBytesLimit

  let maximumBytes: Int
  private var bytes: RigidArray<UInt8>
  private var count = 0
  private(set) var isTooLarge = false

  init(maximumBytes: Int) {
    precondition(maximumBytes > 0 && maximumBytes <= Self.maximumSupportedBytes)
    self.maximumBytes = maximumBytes
    bytes = RigidArray(repeating: 0, count: maximumBytes)
  }

  var isEmpty: Bool { count == 0 }

  mutating func reset() {
    count = 0
    isTooLarge = false
  }

  mutating func append(_ byte: UInt8) {
    guard !isTooLarge else { return }
    guard count < maximumBytes else {
      isTooLarge = true
      return
    }
    bytes[count] = byte
    count += 1
  }

  mutating func append(_ payload: Span<UInt8>) {
    guard !isTooLarge else { return }
    guard payload.count <= maximumBytes - count else {
      isTooLarge = true
      return
    }
    for index in payload.indices { bytes[count + index] = payload[index] }
    count += payload.count
  }

  @_lifetime(borrow self)
  borrowing func text() throws(PasteError) -> UTF8Span {
    precondition(!isTooLarge, "An oversized paste must be rejected before reading its text")
    do { return try UTF8Span(validating: bytes.span.extracting(first: count)) } catch { throw .invalidUTF8 }
  }
}
