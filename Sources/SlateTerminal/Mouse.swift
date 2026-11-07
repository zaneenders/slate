public import SlateUI

public enum MouseButton: Equatable, Sendable {
  case none, left, middle, right
}

public enum MouseAction: Equatable, Sendable {
  case press, release, move, scrollUp, scrollDown, scrollLeft, scrollRight
}

/// SGR mouse input in zero-based terminal cells. Motion's button is the reported
/// held button (or none); scroll events have no button. Coordinates are bounded
/// to 0...65,534. Tracking is opt-in through `Output.mouseTracking()`.
public struct MouseEvent: Equatable, Sendable {
  public let action: MouseAction
  public let button: MouseButton
  private let columnCell: UInt16
  private let rowCell: UInt16
  public var column: Int { Int(columnCell) }
  public var row: Int { Int(rowCell) }
  public let modifiers: KeyModifiers

  public init(
    action: MouseAction, button: MouseButton = .none, column: Int, row: Int,
    modifiers: KeyModifiers = []
  ) {
    precondition((0..<65_535).contains(column) && (0..<65_535).contains(row))
    self.action = action
    self.button = button
    columnCell = UInt16(column)
    rowCell = UInt16(row)
    self.modifiers = modifiers
  }
}
