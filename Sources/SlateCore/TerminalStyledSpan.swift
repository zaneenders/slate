/// A run of text with uniform styling, for use with ``TerminalCellGrid/blitSpans(column:row:maxWidth:_:)``.
public struct TerminalStyledSpan: Sendable {
  public var text: String
  public var foreground: TerminalRGB
  public var background: TerminalRGB
  public var flags: TerminalCellFlags

  public init(
    _ text: String,
    foreground: TerminalRGB,
    background: TerminalRGB,
    flags: TerminalCellFlags = []
  ) {
    self.text = text
    self.foreground = foreground
    self.background = background
    self.flags = flags
  }
}
