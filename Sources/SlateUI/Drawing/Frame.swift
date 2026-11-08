/// An exclusive view of one frame's cells. It cannot escape the draw call.
public struct Frame: ~Copyable, ~Escapable, ~Sendable {
  @usableFromInline var cells: MutableSpan<Cell>
  public let area: Rect

  @_lifetime(copy cells)
  init(cells: consuming MutableSpan<Cell>, size: TerminalSize) {
    precondition(cells.count == size.columns * size.rows)
    self.cells = consume cells
    area = Rect(width: size.columns, height: size.rows)
  }

  @inlinable public subscript(x: Int, y: Int) -> Cell {
    get {
      precondition(x >= 0 && x < area.width && y >= 0 && y < area.height)
      return cells[y * area.width + x]
    }
    set {
      precondition(x >= 0 && x < area.width && y >= 0 && y < area.height)
      let index = y * area.width + x
      // Keep ordinary cell writes visible across target boundaries; passing an
      // 80-byte owned glyph through an out-of-line setter dominates ASCII paint.
      if newValue.glyph.columnWidth == 1 && cells[index].glyph.columnWidth == 1 {
        cells[index] = newValue
      } else {
        put(newValue, x: x, y: y)
      }
    }
  }

  public mutating func fill(_ area: Rect, with cell: Cell = Cell()) {
    let clipped = self.area.intersection(area)
    guard !clipped.isEmpty else { return }
    let value = cell.isContinuation ? Cell(style: cell.style) : cell
    for y in clipped.y..<clipped.bottom {
      let start = y * self.area.width + clipped.x
      let end = start + clipped.width
      // Interior footprints are completely overwritten. Repair only footprints
      // crossing the two edges, then fill the contiguous run without per-cell
      // neighbor checks (the common background/clear path).
      if clipped.x > 0 && cells[start].isContinuation { cells[start - 1] = Cell(style: cells[start - 1].style) }
      if clipped.right < self.area.right && cells[end - 1].glyph.columnWidth == 2 {
        cells[end] = Cell(style: cells[end].style)
      }
      var index = start
      while index < end {
        if value.glyph.columnWidth == 2 {
          if index + 1 == end {
            cells[index] = Cell(style: value.style)
            index += 1
          } else {
            cells[index] = value
            cells[index + 1] = .continuation(style: value.style)
            index += 2
          }
        } else {
          cells[index] = value
          index += 1
        }
      }
    }
  }

  /// Clips hard lines without wrapping. Examines at most 4,096 Unicode scalars.
  /// Controls are replaced, except LF, which advances to the next line.
  public mutating func text(_ text: borrowing String, in area: Rect, style: Style = Style()) {
    let clipped = self.area.intersection(area)
    guard !clipped.isEmpty else { return }
    let utf8 = text.utf8Span
    if utf8.isKnownASCII {
      paintASCII(utf8, origin: area, clipped: clipped, style: style)
      return
    }
    var x = area.x
    var y = area.y
    var count = 0
    var byteOffset = 0
    var clusters = UnicodeGraphemeBuffer()
    for scalar in text.unicodeScalars {
      guard count < LayoutLimits.maximumTextScalars && y < clipped.bottom else { break }
      if let cluster = clusters.append(scalar, at: byteOffset) {
        paint(cluster, origin: area, clipped: clipped, x: &x, y: &y, style: style)
      }
      count += 1
      byteOffset += scalar.utf8Length
    }
    if let cluster = clusters.take() { paint(cluster, origin: area, clipped: clipped, x: &x, y: &y, style: style) }
  }

  private mutating func paintASCII(_ text: UTF8Span, origin: Rect, clipped: Rect, style: Style) {
    let bytes = text.span
    var x = origin.x
    var y = origin.y
    var previousCR = false
    for index in 0..<min(bytes.count, LayoutLimits.maximumTextScalars) {
      guard y < clipped.bottom else { break }
      let byte = bytes[index]
      if byte == 13 || byte == 10 {
        if byte == 13 || !previousCR {
          x = origin.x
          y += 1
        }
      } else {
        if x >= clipped.x && x < clipped.right && y >= clipped.y {
          put(Cell(Glyph(Unicode.Scalar(byte)) ?? .replacement, style: style), x: x, y: y)
        }
        x = min(x + 1, origin.right)
      }
      previousCR = byte == 13
    }
  }

  private mutating func paint(
    _ cluster: UnicodeGrapheme, origin: Rect, clipped: Rect,
    x: inout Int, y: inout Int, style: Style
  ) {
    if cluster.firstScalar == "\n" || cluster.firstScalar == "\r" {
      x = origin.x
      y += 1
      return
    }
    let end = x + cluster.glyph.columnWidth
    if y >= clipped.y && y < clipped.bottom {
      if x >= clipped.x && end <= clipped.right {
        put(Cell(cluster.glyph, style: style), x: x, y: y)
      } else {
        // A wide glyph intersecting either clip edge becomes styled blanks.
        for column in max(x, clipped.x)..<max(max(x, clipped.x), min(end, clipped.right)) {
          put(Cell(style: style), x: column, y: y)
        }
      }
    }
    // Saturate while still recognizing later hard line breaks.
    x = min(end, origin.right)
  }

  /// All writes preserve wide-cell footprints, including writes over a trailing
  /// half. At most the target and two neighbors are touched, within this row.
  @usableFromInline mutating func put(_ value: Cell, x: Int, y: Int) {
    let index = y * area.width + x
    if value.glyph.columnWidth == 1 && cells[index].glyph.columnWidth == 1 {
      cells[index] = value
      return
    }
    if value.isContinuation {
      if x > 0 && cells[index - 1].glyph.columnWidth == 2 {
        cells[index - 1].style = value.style
        cells[index] = value
      } else {
        cells[index] = Cell(style: value.style)
      }
      return
    }
    if cells[index].isContinuation && x > 0 { cells[index - 1] = Cell(style: cells[index - 1].style) }
    if cells[index].glyph.columnWidth == 2 && x + 1 < area.width {
      cells[index + 1] = Cell(style: cells[index + 1].style)
    }
    if value.glyph.columnWidth == 2 {
      guard x + 1 < area.width else {
        cells[index] = Cell(style: value.style)
        return
      }
      if cells[index + 1].glyph.columnWidth == 2 && x + 2 < area.width {
        cells[index + 2] = Cell(style: cells[index + 2].style)
      }
      cells[index] = value
      cells[index + 1] = .continuation(style: value.style)
    } else {
      cells[index] = value
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
      put(Cell(Glyph(scalar)!, style: style), x: x, y: y)
    }
  }
}
