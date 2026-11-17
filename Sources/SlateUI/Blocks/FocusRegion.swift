extension Block {
  /// Registers a keyboard/mouse focus target using its resolved, clipped bounds.
  /// Apply after padding/border and before position, as with hitRegion. Painting
  /// remains caller-owned; use FocusState.isFocused to choose a highlight.
  public func focusTarget<ID: Hashable>(_ id: ID, in focus: FocusState<ID>, enabled: Bool = true) -> some Block {
    FocusRegion(
      content: self, id: id, focus: focus, enabled: enabled, visibility: .visible, neighbors: .automatic)
  }

  /// A named pane can declare logical neighbors for layouts that show one pane
  /// at a time. Focusing a collapsed pane lets its owner reveal it next frame.
  public func navigationRegion<ID: Hashable>(
    _ id: ID, in focus: FocusState<ID>, enabled: Bool,
    visibility: FocusVisibility, neighbors: FocusNeighbors<ID>
  ) -> some Block {
    FocusRegion(content: self, id: id, focus: focus, enabled: enabled, visibility: visibility, neighbors: neighbors)
  }

  /// A semantic navigation boundary. Arrows search this group before leaving it
  /// for a sibling region. Groups can nest and do not paint or change sizing.
  public func navigationGroup<ID: Hashable>(in focus: FocusState<ID>) -> some Block {
    FocusRegion(
      content: self, id: nil, focus: focus, enabled: true, visibility: .visible, neighbors: .automatic)
  }
}

private struct FocusRegion<Content: Block, ID: Hashable>: Block, ~Sendable {
  typealias Body = Never
  let content: Content
  let id: ID?
  let focus: FocusState<ID>
  let enabled: Bool
  let visibility: FocusVisibility
  let neighbors: FocusNeighbors<ID>

  borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try builder.focusRegion(
      content, id: id, storage: focus.storage, enabled: enabled, visibility: visibility, neighbors: neighbors)
  }
}
