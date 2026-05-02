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
}
