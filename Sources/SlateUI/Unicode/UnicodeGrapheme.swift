/// The only adapter to Swift's underscored streaming recognizer. The pinned
/// Swift 6.4.2 API is public and its state matches String's grapheme boundaries.
/// Keep this dependency here; compatibility tests compare it with String and
/// UTF8Span whenever the toolchain changes. No additional compiler features.
public struct UnicodeGraphemeRecognizer: Sendable, Equatable {
  private var state = Unicode._CharacterRecognizer()
  public init() {}
  public mutating func hasBreak(before scalar: Unicode.Scalar) -> Bool { state.hasBreak(before: scalar) }
}

/// One bounded fragment with its original byte range. Controls are retained as
/// firstScalar for the caller's line/tab policy, but never emitted in glyph.
public struct UnicodeGrapheme: Sendable {
  public let glyph: Glyph
  public let firstScalar: Unicode.Scalar
  public let byteRange: Range<Int>
}

/// Streaming collection in 64 inline bytes. Swift performs segmentation. A
/// longer grapheme is split at scalar boundaries into replacement fragments;
/// recognizer state continues across those fragments. Every input scalar does
/// bounded work, so callers can impose byte/scalar budgets independently.
public struct UnicodeGraphemeBuffer: Sendable {
  private var recognizer = UnicodeGraphemeRecognizer()
  private var bytes = InlineArray<64, UInt8>(repeating: 0)
  private var count = 0
  private var scalars = 0
  private var first: Unicode.Scalar = " "
  private var start = 0
  private var end = 0
  private var fragmented = false
  private var initialRecognizer = UnicodeGraphemeRecognizer()
  private var initialFragmented = false

  public init() {}
  public init(recognizer: UnicodeGraphemeRecognizer, fragmented: Bool) {
    self.recognizer = recognizer
    self.fragmented = fragmented
  }
  private var isEmpty: Bool { count == 0 }

  /// Owned state before the current fragment's first scalar. A file viewport
  /// can retain this at row boundaries and resume without replaying a disk page.
  public var initialState: (recognizer: UnicodeGraphemeRecognizer, fragmented: Bool) {
    (initialRecognizer, initialFragmented)
  }

  public mutating func append(_ scalar: Unicode.Scalar, at offset: Int, sourceBytes: Int? = nil) -> UnicodeGrapheme? {
    let length = scalar.utf8Length
    let before = recognizer
    let boundary = recognizer.hasBreak(before: scalar)
    let overflow = count + length > Glyph.maximumUTF8Bytes
    var completed: UnicodeGrapheme?
    if !isEmpty && (boundary || overflow) { completed = take(replacing: !boundary || fragmented) }
    if boundary { fragmented = false } else if overflow { fragmented = true }
    if isEmpty {
      first = scalar
      start = offset
      initialRecognizer = before
      initialFragmented = fragmented
    }
    UTF8.encode(scalar) { byte in
      bytes[count] = byte
      count += 1
    }
    scalars += 1
    end = offset + (sourceBytes ?? length)
    return completed
  }

  public mutating func take(replacing: Bool = false) -> UnicodeGrapheme? {
    guard !isEmpty else { return nil }
    let text = unsafe UTF8Span(unchecked: bytes.span.extracting(first: count))
    let result = UnicodeGrapheme(
      glyph: replacing || fragmented ? .replacement : (scalars == 1 ? Glyph(first) : Glyph(text)) ?? .replacement,
      firstScalar: first, byteRange: start..<end)
    count = 0
    scalars = 0
    return result
  }
}

extension Unicode.Scalar {
  var utf8Length: Int { value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4 }
}
