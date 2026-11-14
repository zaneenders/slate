import Slate

enum KeyboardTheme {
  static let background = Color.rgb(10, 15, 26)
  static let panel = Color.rgb(19, 27, 43)
  static let accent = Color.rgb(88, 225, 180)
  static let text = Color.rgb(223, 233, 250)
  static let muted = Color.rgb(151, 170, 195)
}

enum KeyboardWheelGeometry {
  // A fixed outline helps the terminal's rectangular cells read as a wheel.
  static let ring: InlineArray<32, SIMD2<Int>> = [
    [0, -1000], [195, -981], [383, -924], [556, -831],
    [707, -707], [831, -556], [924, -383], [981, -195],
    [1000, 0], [981, 195], [924, 383], [831, 556],
    [707, 707], [556, 831], [383, 924], [195, 981],
    [0, 1000], [-195, 981], [-383, 924], [-556, 831],
    [-707, 707], [-831, 556], [-924, 383], [-981, 195],
    [-1000, 0], [-981, -195], [-924, -383], [-831, -556],
    [-707, -707], [-556, -831], [-383, -924], [-195, -981]
  ]
  static func button(_ sector: Int, width: Int, height: Int) -> Rect {
    let cx = width / 2
    let cy = height / 2
    let dx = max(0, (width - 9) / 2)
    let dy = max(0, (height - 1) / 2)
    let x: Int
    let y: Int
    switch sector {
    case 0:
      x = cx
      y = cy - dy
    case 1:
      x = cx + dx * 3 / 4
      y = cy - dy * 3 / 4
    case 2:
      x = cx + dx
      y = cy
    case 3:
      x = cx + dx * 3 / 4
      y = cy + dy * 3 / 4
    case 4:
      x = cx
      y = cy + dy
    case 5:
      x = cx - dx * 3 / 4
      y = cy + dy * 3 / 4
    case 6:
      x = cx - dx
      y = cy
    default:
      x = cx - dx * 3 / 4
      y = cy - dy * 3 / 4
    }
    return Rect(x: x - 4, y: y, width: 9, height: 1)
  }
  static func hit(column: Int, row: Int, width: Int, height: Int, right: Bool) -> Int? {
    // Match drawing exactly. Clipped/tiny wheels don't accept ambiguous clicks.
    guard width >= 23 && height >= 7 else { return nil }
    for sector in 0..<8 where !right || sector % 2 == 0 {
      if button(sector, width: width, height: height).contains(column: column, row: row) { return sector }
    }
    return nil
  }
}

final class KeyboardWheelDrawing: CanvasDrawing, ~Sendable {
  var session: KeyboardSession
  let right: Bool
  init(session: KeyboardSession, right: Bool) {
    self.session = session
    self.right = right
  }
  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: KeyboardTheme.panel)))
    guard frame.area.width >= 23 && frame.area.height >= 7 else {
      frame.text("Enlarge for wheel", in: frame.area, style: Style(foreground: KeyboardTheme.muted))
      return
    }
    let dx = (frame.area.width - 9) / 2
    let dy = (frame.area.height - 1) / 2
    for index in 0..<32 {
      let point = KeyboardWheelGeometry.ring[index]
      let x = frame.area.width / 2 + point.x * dx / 1000
      let y = frame.area.height / 2 + point.y * dy / 1000
      frame[x, y] = Cell(
        Glyph("·")!, style: Style(foreground: KeyboardTheme.muted, background: KeyboardTheme.panel, dim: true))
    }
    for sector in 0..<8 where !right || sector % 2 == 0 {
      let bounds = KeyboardWheelGeometry.button(sector, width: frame.area.width, height: frame.area.height)
      let selected =
        right
        ? session.rightPreview == sector
        : session.leftPreview == sector
          || session.selectedGroup == sector && (session.mode == .chords || session.moreLetters)
      let style = Style(
        foreground: selected ? KeyboardTheme.background : KeyboardTheme.text,
        background: selected ? KeyboardTheme.accent : KeyboardTheme.panel, bold: selected)
      frame.fill(bounds, with: Cell(style: style))
      if right {
        if session.mode == .predictive {
          let label: String
          switch sector {
          case 0: label = "first"
          case 2: label = "next >"
          case 4: label = "last"
          default: label = "< prev"
          }
          frame.text(label, in: Rect(x: bounds.x + 1, y: bounds.y, width: 8, height: 1), style: style)
        } else if let group = session.rightPreview != nil ? session.latchedGroup : session.selectedGroup,
          let byte = KeyboardLetters.letter(group: group, sector: sector, extras: session.mode == .common)
        {
          frame[bounds.x + 4, bounds.y] = Cell(Glyph(Unicode.Scalar(session.cased(byte)))!, style: style)
        }
      } else if session.mode == .common && !session.moreLetters {
        frame[bounds.x + 4, bounds.y] = Cell(
          Glyph(Unicode.Scalar(session.cased(KeyboardLetters.common[sector])))!, style: style)
      } else {
        let text = session.mode == .common ? KeyboardLetters.extraLabels[sector] : KeyboardLetters.groupLabels[sector]
        frame.text(
          text, in: Rect(x: bounds.x + (9 - text.utf8.count) / 2, y: bounds.y, width: 8, height: 1), style: style)
      }
    }
    let center: String
    if right {
      center = session.mode == .predictive ? "WORDS" : "LETTER"
    } else {
      center =
        session.mode == .predictive
        ? "FLICK" : session.moreLetters ? "MORE" : session.mode == .common ? "COMMON" : "GROUP"
    }
    frame.text(
      center,
      in: Rect(x: max(0, (frame.area.width - center.utf8.count) / 2), y: frame.area.height / 2, width: 7, height: 1),
      style: Style(foreground: KeyboardTheme.accent, background: KeyboardTheme.panel))
  }
}

final class KeyboardDraftDrawing: CanvasDrawing, ~Sendable {
  var session: KeyboardSession
  init(session: KeyboardSession) { self.session = session }
  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: KeyboardTheme.panel)))
    let width = frame.area.width
    let height = frame.area.height
    guard width > 0 && height > 0 else { return }
    let preview = session.preview.utf8Span
    let previewCount = session.tokenCount == 0 ? 0 : max(preview.count, session.tokenCount)
    let total = session.draft.count + previewCount
    // Scroll in whole rows, leaving room for the caret at the end.
    let firstRow = max(0, total / width - height + 1)
    let start = firstRow * width
    let end = min(total + 1, start + width * height)
    for offset in start..<end {
      let x = (offset - start) % width
      let y = (offset - start) / width
      if offset == total {
        frame[x, y] = Cell(Glyph("_")!, style: Style(foreground: KeyboardTheme.accent, background: KeyboardTheme.panel))
      } else if offset < session.draft.count {
        frame[x, y] = Cell(
          Glyph(Unicode.Scalar(session.draft[offset]))!,
          style: Style(foreground: KeyboardTheme.text, background: KeyboardTheme.panel))
      } else {
        let index = offset - session.draft.count
        let byte = index < preview.count ? session.cased(preview.span[index]) : UInt8(63)
        frame[x, y] = Cell(
          Glyph(Unicode.Scalar(byte))!,
          style: Style(foreground: KeyboardTheme.accent, background: KeyboardTheme.panel, underlined: true))
      }
    }
  }
}
