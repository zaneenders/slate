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
    try builder.build(content)
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
    try builder.build(content)
  }
}

/// Places children in one rectangle, painting from back to front in source order.
/// Its natural size is the largest child on each axis. Use `frame` to request a
/// fixed or filling region; children remain clipped to their allocated bounds.
/// Children with fit sizing keep their natural size; fill sizing uses the region.
/// Unpainted cells reveal earlier children. Fill a child's background to make an
/// opaque panel. Layers share the frame grid and consume ordinary layout nodes.
public struct Overlay<Content: Block>: Block, ~Sendable {
  public typealias Body = Never
  let alignment: Alignment
  let content: Content

  public init(alignment: Alignment = .topLeading, @BlockBuilder content: () -> Content) {
    self.alignment = alignment
    self.content = content()
  }

  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(LayoutNode(kind: .overlay, alignment: alignment))
    defer { builder.end(parent) }
    try builder.build(content)
  }
}
