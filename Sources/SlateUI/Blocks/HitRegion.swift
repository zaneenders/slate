extension Block {
  /// Registers this block's resolved rectangle. Apply after padding/border to
  /// include them; apply before position to target the content rather than its slot.
  public func hitRegion<ID: Hashable>(_ id: ID, in map: HitMap<ID>) -> some Block {
    HitRegion(content: self, id: id, map: map)
  }

  /// Blocks targets behind this rectangle in the same map. Nested hit regions
  /// remain interactive. Untagged decoration otherwise passes through.
  public func blocksMouse<ID: Hashable>(in map: HitMap<ID>) -> some Block {
    HitRegion(content: self, id: nil, map: map)
  }
}

private struct HitRegion<Content: Block, ID: Hashable>: Block, ~Sendable {
  typealias Body = Never
  let content: Content
  let id: ID?
  let map: HitMap<ID>

  borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try builder.hitRegion(content, id: id, map: map)
  }
}
