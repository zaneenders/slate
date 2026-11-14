import Slate

/// One startup-owned drag capture. Mouse events only replace integer geometry;
/// no event history, tasks, or growing storage are retained.
final class PanelDrag: ~Sendable {
  static let width = 30
  static let height = 7
  enum Target: Hashable { case panel }
  let hits = HitMap<Target>(capacity: 1)
  private var capture = MouseCapture<Target>()

  private struct Offset {
    var column: Int
    var row: Int
  }

  private var position: Offset?
  private var grab: Offset?
  private var viewport = TerminalSize(columns: 0, rows: 0)
  private(set) var container = Rect(width: 0, height: 0)
  private(set) var bounds = Rect(width: 0, height: 0)

  var isDragging: Bool { capture.target != nil }
  var column: Int { bounds.x - container.x }
  var row: Int { bounds.y - container.y }

  func prepare(in size: TerminalSize) {
    if size != viewport { cancel() }
    viewport = size
    let padded = Rect(width: size.columns, height: size.rows).inset()
    // The surrounding column reserves a header, footer, and two one-cell gaps.
    container = Rect(
      x: padded.x, y: padded.y + min(2, padded.height),
      width: padded.width, height: max(0, padded.height - 4))
    let width = min(Self.width, container.width)
    let height = min(Self.height, container.height)
    let column = min(position?.column ?? (container.width - width) / 2, container.width - width)
    let row = min(position?.row ?? (container.height - height) / 2, container.height - height)
    bounds = Rect(x: container.x + column, y: container.y + row, width: width, height: height)
    if position != nil { position = Offset(column: column, row: row) }
  }

  func cancel() {
    grab = nil
    capture.end()
  }

  func handle(_ event: MouseEvent) -> ScreenUpdate {
    switch event.action {
    case .press:
      cancel()
      if event.button == .left, let hit = hits.hitTest(event), hit.row == 0 {
        capture.begin(hit, in: hits)
        grab = Offset(column: hit.column, row: hit.row)
      }
      return .none
    case .move:
      guard capture.route(event) != nil else {
        cancel()
        return .none
      }
      return move(to: event)
    case .release:
      let update = capture.route(event) != nil ? move(to: event) : .none
      cancel()
      return update
    case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
      return .none
    }
  }

  private func move(to event: MouseEvent) -> ScreenUpdate {
    guard let grab else { return .none }
    let column = min(max(0, event.column - container.x - grab.column), container.width - bounds.width)
    let row = min(max(0, event.row - container.y - grab.row), container.height - bounds.height)
    guard column != self.column || row != self.row else { return .none }
    position = Offset(column: column, row: row)
    bounds = Rect(x: container.x + column, y: container.y + row, width: bounds.width, height: bounds.height)
    return .redraw
  }
}
