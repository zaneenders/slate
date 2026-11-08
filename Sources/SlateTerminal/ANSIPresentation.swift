import SlateUI

extension ANSIWriter {
  /// Encodes a surface's visible top-left cells at an absolute terminal origin.
  /// An empty previous frame requests a full repaint; otherwise matching cells
  /// are skipped. Owners choose clearing, cursor preservation, and recovery.
  /// Visits at most size.columns * size.rows cells using the existing writer.
  @inline(__always)
  mutating func cells(
    _ current: Span<Cell>, size: TerminalSize, in region: Rect,
    previous: Span<Cell> = .init(), to output: borrowing Output
  ) throws(IOError) -> Int {
    precondition(current.count == size.columns * size.rows)
    precondition(region.width <= size.columns && region.height <= size.rows)
    precondition(previous.isEmpty || previous.count == current.count)
    let repaint = previous.isEmpty
    var lastStyle: Style?
    // Diff complete rows in one pass so unchanged cells need only one comparison.
    if !repaint && region.width == size.columns {
      let count = region.width * region.height
      return try cellRun(
        current.extracting(first: count), columns: region.width, x: region.x, y: region.y,
        previous: previous.extracting(first: count), lastStyle: &lastStyle, to: output)
    }
    var changed = 0
    for row in 0..<region.height {
      let start = row * size.columns
      let end = start + region.width
      changed += try cellRun(
        current.extracting(start..<end), columns: region.width, x: region.x, y: region.y + row,
        previous: previous.extracting(repaint ? 0..<0 : start..<end), lastStyle: &lastStyle, to: output)
    }
    return changed
  }

  @inline(__always)
  private mutating func cellRun(
    _ current: Span<Cell>, columns: Int, x: Int, y: Int, previous: Span<Cell>,
    lastStyle: inout Style?, to output: borrowing Output
  ) throws(IOError) -> Int {
    precondition(previous.isEmpty || previous.count == current.count)
    let repaint = previous.isEmpty
    var changed = 0
    var lastIndex = -2
    var index = 0
    while index < current.count {
      let column = index % columns
      var cell = current[index]
      if cell.isContinuation {
        // Its leading glyph already advanced the terminal cursor two columns.
        // A clipped/orphan continuation is rendered as a styled blank.
        if column > 0 && current[index - 1].glyph.columnWidth == 2 {
          index += 1
          continue
        }
        cell = Cell(style: cell.style)
      }
      if cell.glyph.columnWidth == 2 && column + 1 == columns { cell = Cell(style: cell.style) }
      let width = cell.glyph.columnWidth
      var equal = !repaint && cell == previous[index]
      if equal && width == 2 { equal = current[index + 1] == previous[index + 1] }
      if equal {
        index += width
        continue
      }
      if index != lastIndex + 1 || index.isMultiple(of: columns) {
        try cursor(x: x + index % columns, y: y + index / columns, to: output)
      }
      if cell.style != lastStyle {
        try style(cell.style, previous: lastStyle, to: output)
        lastStyle = cell.style
      }
      try glyph(cell.glyph, to: output)
      lastIndex = index + width - 1
      changed += width
      index += width
    }
    return changed
  }
}
