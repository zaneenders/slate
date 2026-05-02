/// sRGB triplet for truecolor SGR (`38;2` / `48;2`).
public struct TerminalRGB: Equatable, Hashable, Sendable {
  public var r: UInt8
  public var g: UInt8
  public var b: UInt8

  public init(r: UInt8, g: UInt8, b: UInt8) {
    (self.r, self.g, self.b) = (r, g, b)
  }

  public static let black: TerminalRGB = .init(r: 0, g: 0, b: 0)
  public static let white: TerminalRGB = .init(r: 255, g: 255, b: 255)
}
