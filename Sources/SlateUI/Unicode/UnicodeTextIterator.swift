/// A borrowed, bounded grapheme-fragment iterator. Swift supplies scalar
/// decoding and segmentation; skipForward/byte ranges avoid Character storage.
struct UnicodeTextIterator: ~Copyable, ~Escapable {
  private var scalars: UTF8Span.UnicodeScalarIterator
  private var buffer = UnicodeGraphemeBuffer()
  private var remainingScalars: Int
  private var finished = false

  @_lifetime(copy text)
  init(_ text: UTF8Span, maximumScalars: Int = .max) {
    scalars = text.makeUnicodeScalarIterator()
    remainingScalars = maximumScalars
  }

  @_lifetime(self: copy self)
  mutating func next() -> UnicodeGrapheme? {
    guard !finished else { return nil }
    while remainingScalars > 0 {
      let start = scalars.currentCodeUnitOffset
      guard let scalar = scalars.next() else { break }
      remainingScalars -= 1
      if let complete = buffer.append(scalar, at: start) { return complete }
    }
    finished = true
    return buffer.take()
  }
}
