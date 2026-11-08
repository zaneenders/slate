extension TextInput {
  func paint(in area: Rect, frame: inout Frame, focused: Bool, placeholder: String, style: Style) {
    withText { text in
      paint(text, in: area, frame: &frame, focused: focused, placeholder: placeholder, style: style)
    }
  }

  private func paint(
    _ text: UTF8Span, in area: Rect, frame: inout Frame, focused: Bool, placeholder: String, style: Style
  ) {
    guard !area.isEmpty else { return }
    let line = Rect(x: area.x, y: area.y, width: area.width, height: 1)
    frame.fill(line, with: Cell(style: style))
    if byteCount == 0 {
      var placeholderStyle = style
      placeholderStyle.dim = true
      frame.text(placeholder, in: line, style: placeholderStyle)
    }
    // Editing still follows Swift Character boundaries. Painting measures the
    // same bounded grapheme fragments used by the other rendering paths.
    var characters = UnicodeTextIterator(text)
    var cursorColumn = 0
    while let cluster = characters.next() {
      if cluster.byteRange.upperBound > cursorByteOffset { break }
      cursorColumn += cluster.glyph.columnWidth
    }
    let firstColumn = focused ? max(0, cursorColumn - area.width + 1) : 0
    var visible = UnicodeTextIterator(text)
    var column = 0
    let selected = selection
    while column < firstColumn + area.width, let cluster = visible.next() {
      let start = cluster.byteRange.lowerBound
      let glyph = cluster.glyph
      if column >= firstColumn && column + glyph.columnWidth <= firstColumn + area.width {
        var cellStyle = style
        if focused && selected.contains(start) { cellStyle.inverse.toggle() }
        if focused && start == cursorByteOffset {
          cellStyle.underlined = true
          cellStyle.inverse.toggle()
        }
        let x = area.x + column - firstColumn
        if x < frame.area.right && area.y < frame.area.bottom { frame[x, area.y] = Cell(glyph, style: cellStyle) }
      }
      column += glyph.columnWidth
    }
    if focused && cursorByteOffset == byteCount {
      let x = area.x + cursorColumn - firstColumn
      if x < frame.area.right && area.y < frame.area.bottom {
        var cell = frame[x, area.y]
        cell.style.inverse.toggle()
        cell.style.underlined = true
        frame[x, area.y] = cell
      }
    }
  }
}
