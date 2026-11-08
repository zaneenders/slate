import Slate

/// Byte-cell endpoints across scrolled views. All capture state is scalar;
/// selection length does not allocate storage until a copy is requested.
/// Single clicks clear selection; moving selects both endpoint cells. Pointer
/// motion outside the pane clamps to its edges without selecting other regions.
struct DocumentSelection {
  let anchor: Range<Int>
  private(set) var focus: Range<Int>
  private(set) var hasMoved = false

  init(byteOffset: Int) {
    self.init(byteRange: byteOffset..<byteOffset + 1)
  }

  init(byteRange: Range<Int>) {
    precondition(byteRange.lowerBound >= 0 && !byteRange.isEmpty)
    anchor = byteRange
    focus = byteRange
  }

  var range: Range<Int>? {
    guard hasMoved else { return nil }
    return min(anchor.lowerBound, focus.lowerBound)..<max(anchor.upperBound, focus.upperBound)
  }

  mutating func extend(to byteOffset: Int, moved: Bool = false) -> Bool {
    extend(to: byteOffset..<byteOffset + 1, moved: moved)
  }

  mutating func extend(to byteRange: Range<Int>, moved: Bool = false) -> Bool {
    precondition(byteRange.lowerBound >= 0 && !byteRange.isEmpty)
    guard byteRange != focus || (moved && !hasMoved) else { return false }
    focus = byteRange
    hasMoved = true
    return true
  }

  static func byteOffset(
    column: Int, row: Int, area: Rect, viewportSize: TerminalSize,
    visibleRange: Range<Int>, clamp: Bool
  ) -> Int? {
    let columns = min(area.width, viewportSize.columns)
    let rows = min(area.height, viewportSize.rows)
    guard columns > 0, rows > 0, !visibleRange.isEmpty else { return nil }
    if !clamp {
      guard (area.x..<area.x + columns).contains(column), (area.y..<area.y + rows).contains(row) else { return nil }
    }
    let x = min(columns - 1, max(0, column - area.x))
    let y = min(rows - 1, max(0, row - area.y))
    let index = y * viewportSize.columns + x
    if index >= visibleRange.count { return clamp ? visibleRange.upperBound - 1 : nil }
    return visibleRange.lowerBound + index
  }
}
