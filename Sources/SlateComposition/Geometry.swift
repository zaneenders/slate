/// Dimensions in terminal cells. Zero is valid for an empty or unconfigured terminal.
public struct TerminalSize: Equatable, Sendable {
  public let columns: Int
  public let rows: Int

  @inlinable public init(columns: Int, rows: Int) {
    precondition((0...65_535).contains(columns) && (0...65_535).contains(rows))
    self.columns = columns
    self.rows = rows
  }
}

/// A rectangle in terminal cells, with an inclusive origin and exclusive edges.
public struct Rect: Equatable, Sendable {
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int

  @inlinable public init(x: Int = 0, y: Int = 0, width: Int, height: Int) {
    precondition((0...65_535).contains(x) && (0...65_535).contains(y))
    precondition(width >= 0 && width <= 65_535 - x && height >= 0 && height <= 65_535 - y)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  @inlinable public var right: Int { x + width }
  @inlinable public var bottom: Int { y + height }
  @inlinable public var isEmpty: Bool { width == 0 || height == 0 }

  @inlinable public func intersection(_ other: Rect) -> Rect {
    let left = max(x, other.x)
    let top = max(y, other.y)
    return Rect(
      x: left, y: top, width: max(0, min(right, other.right) - left),
      height: max(0, min(bottom, other.bottom) - top))
  }

  @inlinable public func inset(horizontal: Int = 1, vertical: Int = 1) -> Rect {
    precondition((0...65_535).contains(horizontal) && (0...65_535).contains(vertical))
    return Rect(
      x: x + min(horizontal, width), y: y + min(vertical, height),
      width: max(0, width - 2 * horizontal), height: max(0, height - 2 * vertical))
  }
}
