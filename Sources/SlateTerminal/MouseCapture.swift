public import SlateUI

extension HitMap {
  public func hitTest(_ event: MouseEvent) -> Hit<ID>? {
    hitTest(column: event.column, row: event.row)
  }
}

/// One application-owned drag. Capture follows a stable target outside its bounds
/// and ends on release, missing held-button reports, target removal, or resize.
/// Coordinate conversion always uses the target's latest committed bounds.
public struct MouseCapture<ID: Hashable>: ~Sendable {
  private var original: Hit<ID>?
  private var map: HitMap<ID>?
  private var button = MouseButton.left

  public init() {}

  public var target: ID? {
    guard let original, let map,
      map.capturedHit(original, column: original.bounds.x, row: original.bounds.y) != nil
    else { return nil }
    return original.id
  }

  public mutating func begin(_ hit: Hit<ID>, in map: HitMap<ID>, button: MouseButton = .left) {
    precondition(button != .none)
    original = hit
    self.map = map
    self.button = button
  }

  public mutating func end() {
    original = nil
    map = nil
  }

  /// Returns the final release position before ending capture. Presses cancel
  /// the old capture so the application can hit-test and begin a new one.
  public mutating func route(_ event: MouseEvent) -> Hit<ID>? {
    guard let original, let map,
      let hit = map.capturedHit(original, column: event.column, row: event.row)
    else {
      end()
      return nil
    }
    switch event.action {
    case .move:
      guard event.button == button else {
        end()
        return nil
      }
      return hit
    case .release:
      end()
      return event.button == button || event.button == .none ? hit : nil
    case .press:
      end()
      return nil
    case .scrollUp, .scrollDown, .scrollLeft, .scrollRight: return nil
    }
  }
}
