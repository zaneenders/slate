/// One terminal **cell**: a single glyph plus truecolor styles (matches the demo encoder).
public struct TerminalCell: Equatable, Sendable {
  public var glyph: Character
  public var foreground: TerminalRGB
  public var background: TerminalRGB
  public var flags: TerminalCellFlags

  public init(
    glyph: Character,
    foreground: TerminalRGB,
    background: TerminalRGB,
    flags: TerminalCellFlags = []
  ) {
    self.glyph = glyph
    self.foreground = foreground
    self.background = background
    self.flags = flags
  }

  /// A space with default white-on-black styling — suitable as a grid initial fill.
  public static let defaultCell = TerminalCell(
    glyph: " ", foreground: .white, background: .black, flags: [])
}
