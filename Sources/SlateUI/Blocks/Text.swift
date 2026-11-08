public struct Text: Block, Sendable {
  public typealias Body = Never
  let content: String
  let style: Style
  public init(_ content: String, style: Style = Style()) {
    self.content = content
    self.style = style
  }
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try builder.text(content, style: style)
  }
}
