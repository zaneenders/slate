// Keep cell constructors and equality witnesses visible across the target
// boundary so painting and diffing do not add a function call for every cell.

/// The terminal's default color or an entry in its 256-color palette.
public enum Color: Equatable, Sendable {
  case `default`
  case indexed(UInt8)

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

/// A known single-cell glyph: printable ASCII or Unicode box drawing.
/// Other text scalars render as '?' until grapheme/terminal-width support is added.
public struct Glyph: Equatable, Sendable {
  public let scalar: Unicode.Scalar

  @inlinable public init?(_ scalar: Unicode.Scalar) {
    guard (0x20...0x7e).contains(scalar.value) || (0x2500...0x257f).contains(scalar.value) else { return nil }
    self.scalar = scalar
  }

  public static let space = Glyph(" ")!
  public static let replacement = Glyph("?")!

  @inlinable public static func == (left: Self, right: Self) -> Bool { left.scalar == right.scalar }
}

public struct Cell: Equatable, Sendable {
  public var glyph: Glyph
  public var style: Style

  @inlinable public init(_ glyph: Glyph = .space, style: Style = Style()) {
    self.glyph = glyph
    self.style = style
  }

  @inlinable public static func == (left: Self, right: Self) -> Bool {
    left.glyph == right.glyph && left.style == right.style
  }
}
