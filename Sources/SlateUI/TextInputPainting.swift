import SlateComposition

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
    // Swift navigates graphemes without constructing Character/String values.
    var characters = text.makeCharacterIterator()
    var cursorColumn = 0
    while characters.currentCodeUnitOffset < cursorByteOffset {
      _ = characters.skipForward()
      cursorColumn += 1
    }
    let firstColumn = focused ? max(0, cursorColumn - area.width + 1) : 0
    characters.reset(roundingBackwardsFrom: 0)
    var column = 0
    let selected = selection
    while characters.currentCodeUnitOffset < byteCount && column < firstColumn + area.width {
      let start = characters.currentCodeUnitOffset
      _ = characters.skipForward()
      let end = characters.currentCodeUnitOffset
      if column >= firstColumn {
        var scalarIterator = unsafe UTF8Span(unchecked: text.span.extracting(start..<end)).makeUnicodeScalarIterator()
        let scalar = scalarIterator.next()!
        let glyph = scalarIterator.next() == nil ? Glyph(scalar) ?? .replacement : .replacement
        var cellStyle = style
        if focused && selected.contains(start) { cellStyle.inverse.toggle() }
        if focused && start == cursorByteOffset {
          cellStyle.underlined = true
          cellStyle.inverse.toggle()
        }
        let x = area.x + column - firstColumn
        if x < frame.area.right && area.y < frame.area.bottom { frame[x, area.y] = Cell(glyph, style: cellStyle) }
      }
      column += 1
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
