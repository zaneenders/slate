/// sRGB triplet for truecolor SGR (`38;2` / `48;2`).
public struct TerminalRGB: Equatable, Hashable, Sendable {
  public var r: UInt8
  public var g: UInt8
  public var b: UInt8

  public init(r: UInt8, g: UInt8, b: UInt8) {
    (self.r, self.g, self.b) = (r, g, b)
  }

  /// Initialize from a 24-bit hex value: `TerminalRGB(hex: 0xFFA55A)`.
  public init(hex: UInt32) {
    self.r = UInt8((hex >> 16) & 0xFF)
    self.g = UInt8((hex >> 8) & 0xFF)
    self.b = UInt8(hex & 0xFF)
  }

  public static let black: TerminalRGB = .init(r: 0, g: 0, b: 0)
  public static let white: TerminalRGB = .init(r: 255, g: 255, b: 255)

  // MARK: - Common presets

  public static let red = TerminalRGB(r: 255, g: 60, b: 60)
  public static let green = TerminalRGB(r: 60, g: 220, b: 60)
  public static let blue = TerminalRGB(r: 80, g: 160, b: 255)
  public static let yellow = TerminalRGB(r: 255, g: 220, b: 80)
  public static let cyan = TerminalRGB(r: 80, g: 220, b: 220)
  public static let magenta = TerminalRGB(r: 220, g: 80, b: 220)
  public static let orange = TerminalRGB(r: 255, g: 160, b: 60)
  public static let gray = TerminalRGB(r: 128, g: 128, b: 128)
  public static let darkGray = TerminalRGB(r: 64, g: 64, b: 64)
  public static let lightGray = TerminalRGB(r: 192, g: 192, b: 192)
}
