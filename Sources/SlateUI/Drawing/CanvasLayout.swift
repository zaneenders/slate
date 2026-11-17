/// Canvas-local registration against the pending surface layout. Coordinates
/// follow Frame.withRegion; this view cannot escape the synchronous callback.
public struct CanvasLayout: ~Copyable, ~Escapable, ~Sendable {
  public let area: Rect
  private let originColumn: Int
  private let originRow: Int
  private let order: Int
  private let hitMaps: HitMapFrame

  @_lifetime(borrow hitMaps)
  init(bounds: Rect, order: Int, hitMaps: borrowing HitMapFrame) {
    area = Rect(width: bounds.width, height: bounds.height)
    originColumn = bounds.x
    originRow = bounds.y
    self.order = order
    self.hitMaps = copy hitMaps
  }

  /// Visible targets use clipped geometry. Collapsed targets remain reachable
  /// through explicit neighbors so the owner can reveal their pane next frame.
  public mutating func focusTarget<ID: Hashable>(
    _ id: ID, in focus: FocusState<ID>, bounds: Rect, enabled: Bool,
    visibility: FocusVisibility, neighbors: FocusNeighbors<ID>
  ) throws(LayoutError) {
    try hitMaps.register(focus.storage)
    let record = try focus.storage.append(id, enabled: enabled, visibility: visibility, neighbors: neighbors)
    focus.storage.setBounds(surfaceBounds(bounds), at: record)
    _ = focus.storage.enterRegion(at: record, order: order)
  }

  public mutating func navigationGroup<ID: Hashable>(
    in focus: FocusState<ID>, bounds: Rect,
    register: (inout CanvasLayout) throws(LayoutError) -> Void
  ) throws(LayoutError) {
    try hitMaps.register(focus.storage)
    let record = try focus.storage.append(nil, enabled: true, visibility: .visible, neighbors: .automatic)
    focus.storage.setBounds(surfaceBounds(bounds), at: record)
    let previous = focus.storage.enterRegion(at: record, order: order)
    defer { focus.storage.leaveRegion(previous) }
    try register(&self)
  }

  public mutating func withRegion(
    _ bounds: Rect, register: (inout CanvasLayout) throws(LayoutError) -> Void
  ) throws(LayoutError) {
    let clipped = surfaceBounds(bounds)
    guard !clipped.isEmpty else { return }
    var local = CanvasLayout(bounds: clipped, order: order, hitMaps: hitMaps)
    try register(&local)
  }

  private func surfaceBounds(_ bounds: Rect) -> Rect {
    let clipped = area.intersection(bounds)
    guard !clipped.isEmpty else { return Rect(x: originColumn, y: originRow, width: 0, height: 0) }
    return Rect(
      x: originColumn + clipped.x, y: originRow + clipped.y, width: clipped.width, height: clipped.height)
  }
}
