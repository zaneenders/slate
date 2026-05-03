/// sRGB triplet for truecolor SGR (`38;2` / `48;2`).
public struct Color: Equatable, Sendable {
  public var r: UInt8
  public var g: UInt8
  public var b: UInt8

  public init(r: UInt8, g: UInt8, b: UInt8) {
    (self.r, self.g, self.b) = (r, g, b)
  }

  public static let `default` = Color(r: 0, g: 0, b: 0)
  public static let black = Color(r: 0, g: 0, b: 0)
  public static let white = Color(r: 255, g: 255, b: 255)
  public static let red = Color(r: 255, g: 0, b: 0)
  public static let green = Color(r: 0, g: 255, b: 0)
  public static let blue = Color(r: 0, g: 0, b: 255)
  public static let cyan = Color(r: 0, g: 255, b: 255)
  public static let magenta = Color(r: 255, g: 0, b: 255)
  public static let yellow = Color(r: 255, g: 255, b: 0)
}

public struct Style: OptionSet, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let bold = Style(rawValue: 1 << 0)
  public static let italic = Style(rawValue: 1 << 1)
  public static let underline = Style(rawValue: 1 << 2)
  public static let strikethrough = Style(rawValue: 1 << 3)
}

public struct Attributes: Equatable, Sendable {
  public var foreground: Color
  public var background: Color
  public var style: Style

  public init(foreground: Color, background: Color, style: Style = []) {
    self.foreground = foreground
    self.background = background
    self.style = style
  }

  public static let `default` = Attributes(
    foreground: .white,
    background: .black
  )
}

/// One terminal cell: a single glyph plus truecolor styles.
public struct Cell: Equatable, Sendable {
  public var char: Unicode.Scalar
  public var attrs: Attributes

  public init(char: Unicode.Scalar, attrs: Attributes) {
    self.char = char
    self.attrs = attrs
  }

  public static let `default` = Cell(
    char: " ",
    attrs: .default
  )
}
