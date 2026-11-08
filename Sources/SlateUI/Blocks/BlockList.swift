/// A bounded, homogeneous sequence prepared by the caller before drawing.
/// Slicing immutable array storage does not copy its elements or allocate.
/// Each element is a sibling in the surrounding Row or Column.
public struct BlockList<Content: Block>: Block, ~Sendable {
  public typealias Body = Never
  private let content: ArraySlice<Content>

  public init(_ content: ArraySlice<Content>) {
    self.content = content
  }

  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    // Bound even sequences of empty custom blocks, which consume no nodes.
    guard content.count <= LayoutLimits.maximumNodes else {
      throw .nodeCapacityExceeded
    }
    for block in content { try block._build(into: &builder) }
  }
}
