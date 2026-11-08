import Slate

/// Pure, bounded example layout shared by preparation and painting.
struct DocumentViewerLayout {
  let rich: Bool
  let document: Rect
  let text: Rect
  let inspector: Rect?
  let gutterDigits: Int
  let scrollbarColumn: Int?

  init(size: TerminalSize, byteCount: Int, showInspector: Bool) {
    var digits = 1
    var count = max(1, byteCount - 1)
    while count >= 10 {
      digits += 1
      count /= 10
    }
    gutterDigits = digits
    rich = size.columns >= 48 && size.rows >= 14
    let gutter = size.columns >= 24 ? digits + 2 : 0
    if rich {
      let inspectorWidth = showInspector && size.columns >= 100 && size.rows >= 22 ? 34 : 0
      let width = size.columns - (inspectorWidth > 0 ? inspectorWidth + 1 : 0)
      document = Rect(y: 3, width: width, height: size.rows - 7)
      text = Rect(x: gutter + 1, y: 4, width: max(0, width - gutter - 3), height: size.rows - 9)
      scrollbarColumn = width - 2
      inspector = inspectorWidth > 0 ? Rect(x: width + 1, y: 3, width: inspectorWidth, height: size.rows - 7) : nil
    } else {
      document = Rect(y: min(2, size.rows), width: size.columns, height: max(0, size.rows - 5))
      let scrollbar = size.columns >= 32 ? 1 : 0
      text = Rect(x: gutter, y: document.y, width: max(0, size.columns - gutter - scrollbar), height: document.height)
      scrollbarColumn = scrollbar > 0 ? size.columns - 1 : nil
      inspector = nil
    }
  }
}
