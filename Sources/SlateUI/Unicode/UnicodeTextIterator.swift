/// A borrowed, bounded grapheme-fragment iterator. Swift supplies scalar
/// decoding and segmentation; skipForward/byte ranges avoid Character storage.
struct UnicodeTextIterator: ~Copyable, ~Escapable {
  private var scalars: UTF8Span.UnicodeScalarIterator
  private var buffer = UnicodeGraphemeBuffer()
  private var finished = false

  @_lifetime(copy text)
  init(_ text: UTF8Span) {
    scalars = text.makeUnicodeScalarIterator()
  }

  @_lifetime(self: copy self)
  mutating func next() -> UnicodeGrapheme? {
    guard !finished else { return nil }
    while true {
      let start = scalars.currentCodeUnitOffset
      guard let scalar = scalars.next() else { break }
      if let complete = buffer.append(scalar, at: start) { return complete }
    }
    finished = true
    return buffer.take()
  }
}
