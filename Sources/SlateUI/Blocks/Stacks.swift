public struct Row<Content: Block>: Block, ~Sendable {
  public typealias Body = Never
  let gap: Int
  let alignment: Alignment
  let content: Content
  public init(gap: Int = 0, alignment: Alignment = .topLeading, @BlockBuilder content: () -> Content) {
    precondition((0...65_535).contains(gap))
    self.gap = gap
    self.alignment = alignment
    self.content = content()
  }
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(LayoutNode(kind: .row, alignment: alignment, gap: gap))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}

public struct Column<Content: Block>: Block, ~Sendable {
  public typealias Body = Never
  let gap: Int
  let alignment: Alignment
  let content: Content
  public init(gap: Int = 0, alignment: Alignment = .topLeading, @BlockBuilder content: () -> Content) {
    precondition((0...65_535).contains(gap))
    self.gap = gap
    self.alignment = alignment
    self.content = content()
  }
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(LayoutNode(kind: .column, alignment: alignment, gap: gap))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}
