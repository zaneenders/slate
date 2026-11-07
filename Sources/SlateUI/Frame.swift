public import SlateComposition

/// An exclusive view of one frame's cells. It cannot escape the draw call.
public struct Frame: ~Copyable, ~Escapable {
  private var cells: MutableSpan<Cell>
  public let area: Rect

  @_lifetime(copy cells)
  init(cells: consuming MutableSpan<Cell>, size: TerminalSize) {
    precondition(cells.count == size.columns * size.rows)
    self.cells = consume cells
    area = Rect(width: size.columns, height: size.rows)
  }

  public subscript(x: Int, y: Int) -> Cell {
    get {
      precondition(x >= 0 && x < area.width && y >= 0 && y < area.height)
      return cells[y * area.width + x]
    }
    set {
      precondition(x >= 0 && x < area.width && y >= 0 && y < area.height)
      cells[y * area.width + x] = newValue
    }
  }

  public mutating func fill(_ area: Rect, with cell: Cell = Cell()) {
    let clipped = self.area.intersection(area)
    for y in clipped.y..<clipped.bottom {
      for x in clipped.x..<clipped.right { cells[y * self.area.width + x] = cell }
    }
  }

  /// Clips hard lines without wrapping. Examines at most 4,096 Unicode scalars.
  /// Controls are replaced, except LF, which advances to the next line.
  public mutating func text(_ text: borrowing String, in area: Rect, style: Style = Style()) {
    let clipped = self.area.intersection(area)
    guard !clipped.isEmpty else { return }
    var x = area.x
    var y = area.y
    var remaining = LayoutLimits.maximumTextScalars
    for scalar in text.unicodeScalars {
      guard remaining > 0 && y < clipped.bottom else { break }
      remaining -= 1
      if scalar == "\n" {
        x = area.x
        y += 1
      } else {
        if x >= clipped.x && x < clipped.right && y >= clipped.y {
          cells[y * self.area.width + x] = Cell(Glyph(scalar) ?? .replacement, style: style)
        }
        // Saturate at the right edge while skipping a clipped line's tail.
        x = min(x + 1, area.right)
      }
    }
  }

  /// Draws the original rectangle's border, clipped to this frame.
  public mutating func border(_ area: Rect, title: String = "", style: Style = Style()) {
    guard !area.isEmpty else { return }
    let clipped = self.area.intersection(area)
    guard !clipped.isEmpty else { return }
    // Visit the perimeter rather than every cell inside each nested panel.
    for x in clipped.x..<clipped.right {
      putBorder("─", x: x, y: area.y, style: style)
      if area.height > 1 { putBorder("─", x: x, y: area.bottom - 1, style: style) }
    }
    let firstInteriorRow = max(clipped.y, area.y + 1)
    let endInteriorRow = max(firstInteriorRow, min(clipped.bottom, area.bottom - 1))
    for y in firstInteriorRow..<endInteriorRow {
      putBorder("│", x: area.x, y: y, style: style)
      if area.width > 1 { putBorder("│", x: area.right - 1, y: y, style: style) }
    }
    putBorder("┌", x: area.x, y: area.y, style: style)
    if area.width > 1 { putBorder("┐", x: area.right - 1, y: area.y, style: style) }
    if area.height > 1 {
      putBorder("└", x: area.x, y: area.bottom - 1, style: style)
      if area.width > 1 { putBorder("┘", x: area.right - 1, y: area.bottom - 1, style: style) }
    }
    if area.width > 4 {
      text(title, in: Rect(x: area.x + 2, y: area.y, width: area.width - 4, height: 1), style: style)
    }
  }

  private mutating func putBorder(_ scalar: Unicode.Scalar, x: Int, y: Int, style: Style) {
    if x >= 0 && x < area.width && y >= 0 && y < area.height {
      cells[y * area.width + x] = Cell(Glyph(scalar)!, style: style)
    }
  }
}
