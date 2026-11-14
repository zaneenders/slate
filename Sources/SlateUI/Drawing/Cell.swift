// Keep cell constructors and equality witnesses visible across the target
// boundary so painting and diffing do not add a function call for every cell.

/// A terminal default, palette entry, or explicit 24-bit RGB color.
public enum Color: Equatable, Sendable {
  case `default`
  case indexed(UInt8)
  case rgb(UInt8, UInt8, UInt8)

  public static let black = Color.indexed(0)
  public static let red = Color.indexed(1)
  public static let green = Color.indexed(2)
  public static let yellow = Color.indexed(3)
  public static let blue = Color.indexed(4)
  public static let magenta = Color.indexed(5)
  public static let cyan = Color.indexed(6)
  public static let white = Color.indexed(7)

  @inlinable public static func == (left: Self, right: Self) -> Bool {
    switch (left, right) {
    case (.default, .default): return true
    case (.indexed(let left), .indexed(let right)): return left == right
    case (.rgb(let lr, let lg, let lb), .rgb(let rr, let rg, let rb)):
      return lr == rr && lg == rg && lb == rb
    default: return false
    }
  }
}

public struct Style: Equatable, Sendable {
  public var foreground: Color
  public var background: Color
  public var bold: Bool
  public var dim: Bool
  public var underlined: Bool
  public var inverse: Bool

  @inlinable public init(
    foreground: Color = .default, background: Color = .default,
    bold: Bool = false, dim: Bool = false, underlined: Bool = false, inverse: Bool = false
  ) {
    self.foreground = foreground
    self.background = background
    self.bold = bold
    self.dim = dim
    self.underlined = underlined
    self.inverse = inverse
  }

  @inlinable public static func == (left: Self, right: Self) -> Bool {
    left.foreground == right.foreground && left.background == right.background
      && left.bold == right.bold && left.dim == right.dim
      && left.underlined == right.underlined && left.inverse == right.inverse
  }
}

/// One printable grapheme, owned inline. No String/Character storage or ARC is
/// retained. Terminal width uses Unicode 18 W/F ranges, ambiguous width one,
/// and Swift's emoji properties. A cluster is limited to 64 UTF-8 bytes.
public struct Glyph: Equatable, Sendable {
  public static let maximumUTF8Bytes = 64
  /// The first scalar. Use utf8() to inspect the entire grapheme.
  public let scalar: Unicode.Scalar
  @usableFromInline var bytes: InlineArray<64, UInt8> = .init(repeating: 0)
  @usableFromInline var count: UInt8 = 0
  @usableFromInline var columns: UInt8 = 1

  @inlinable public var byteCount: Int { Int(count) }
  @inlinable public var columnWidth: Int { Int(columns) }

  @inlinable public init?(_ scalar: Unicode.Scalar) {
    self.scalar = scalar
    if (0x20...0x7e).contains(scalar.value) {
      bytes[0] = UInt8(scalar.value)
      count = 1
      return
    }
    guard let width = Self.scalarColumns(scalar), width > 0,
      scalar.properties.generalCategory != .spacingMark, !scalar.properties.isEmojiModifier
    else { return nil }
    columns = UInt8(scalar.properties.isEmojiPresentation ? 2 : width)
    UTF8.encode(scalar) { byte in
      bytes[Int(count)] = byte
      count += 1
    }
  }

  /// Accepts exactly one printable grapheme. Oversized clusters and standalone
  /// marks/format controls reject; layout replaces them without growing storage.
  public init?(_ text: UTF8Span) {
    guard !text.isEmpty && text.count <= Self.maximumUTF8Bytes else { return nil }
    var characters = text.makeCharacterIterator()
    _ = characters.skipForward()
    guard characters.currentCodeUnitOffset == text.count else { return nil }
    var iterator = text.makeUnicodeScalarIterator()
    let first = iterator.next()!
    self.scalar = first
    guard first.properties.generalCategory != .spacingMark, !first.properties.isEmojiModifier else { return nil }
    guard var width = Self.scalarColumns(first) else { return nil }
    var emoji = first.properties.isEmojiPresentation
    var emojiSelector = false
    var textSelector = false
    var keycap = false
    var joiner = false
    while let scalar = iterator.next() {
      guard let nextWidth = Self.scalarColumns(scalar) else { return nil }
      // Grapheme-mode terminals accumulate advancing scalars/spacing marks up
      // to a two-column cell. This covers Indic conjuncts and vowel signs as
      // well as Hangul. Nonspacing/enclosing marks contribute zero columns.
      width = min(2, width + nextWidth)
      emoji = emoji || scalar.properties.isEmojiPresentation
      emojiSelector = emojiSelector || scalar.value == 0xfe0f
      textSelector = textSelector || scalar.value == 0xfe0e
      keycap = keycap || scalar.value == 0x20e3
      joiner = joiner || scalar.value == 0x200d
    }
    guard width > 0 else { return nil }
    if textSelector && first.properties.isEmoji {
      width = 1
    } else if !textSelector && (emoji || (first.properties.isEmoji && (emojiSelector || keycap || joiner))) {
      width = 2
    }
    columns = UInt8(width)
    count = UInt8(text.count)
    let source = text.span
    for index in 0..<text.count { bytes[index] = source[index] }
  }

  public init?(text: borrowing String) { self.init(text.utf8Span) }

  @_lifetime(borrow self)
  public borrowing func utf8() -> UTF8Span {
    unsafe UTF8Span(unchecked: bytes.span.extracting(first: Int(count)))
  }

  /// Zero-width trailing marker for a wide glyph in a prepared grid. It is
  /// never terminal output; Frame creates live continuations when painting.
  public static var continuation: Glyph {
    var result = Glyph.space
    result.count = 0
    result.columns = 0
    return result
  }

  /// Scalar width before grapheme composition; nil rejects unsupported controls.
  public static func scalarColumns(_ scalar: Unicode.Scalar) -> Int? {
    let value = scalar.value
    if (0x20...0x7e).contains(value) { return 1 }
    let properties = scalar.properties
    if properties.isBidiControl || properties.isNoncharacterCodePoint { return nil }
    switch properties.generalCategory {
    case .control, .lineSeparator, .paragraphSeparator, .unassigned: return nil
    case .format:
      // Joiners and emoji tag sequences are meaningful only inside a cluster.
      return value == 0x200c || value == 0x200d || (0xe0020...0xe007f).contains(value) ? 0 : nil
    case .nonspacingMark, .enclosingMark: return 0
    default: return UnicodeWidth.isWide(value) ? 2 : 1
    }
  }

  public static let space = Glyph(" ")!
  public static let replacement = Glyph("?")!

  @inlinable public static func == (left: Self, right: Self) -> Bool {
    guard left.scalar == right.scalar && left.count == right.count && left.columns == right.columns else {
      return false
    }
    // ASCII and individual scalars need no payload comparison.
    let value = left.scalar.value
    let scalarBytes = value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
    if left.count <= 4 && Int(left.count) == scalarBytes { return true }
    for index in 0..<Int(left.count) where left.bytes[index] != right.bytes[index] { return false }
    return true
  }
}

public struct Cell: Equatable, Sendable {
  public var glyph: Glyph
  public var style: Style
  @inlinable public var isContinuation: Bool { glyph.columnWidth == 0 }

  public static func continuation(style: Style) -> Cell { Cell(.continuation, style: style) }

  @inlinable public init(_ glyph: Glyph = .space, style: Style = Style()) {
    self.glyph = glyph
    self.style = style
  }

  @inlinable public static func == (left: Self, right: Self) -> Bool {
    left.glyph == right.glyph && left.style == right.style
  }
}
