import Slate

@main
struct SlateScopedNavigationDemo: ~Copyable, ScreenApplication {
  enum Scope: Hashable { case workspace, help }
  enum Target: Hashable { case notes, reader, help }

  let focus: FocusState<Target>
  let navigation: NavigationRouter<Scope, Target>
  let workspace: NotesDrawing
  let help: HelpDrawing

  init() {
    let focus = FocusState<Target>(capacity: 2, initial: .notes)
    self.focus = focus
    workspace = NotesDrawing(focus: focus)
    help = HelpDrawing()
    navigation = NavigationRouter(root: .workspace, focus: focus, capacity: 2)
  }

  static var configuration: ScreenApplicationConfiguration {
    .init(
      maximumSize: .init(columns: 240, rows: 80), viewportOverflow: .clip,
      mouseTracking: true, enhancedKeyboard: true, kittyGraphicsQueryID: nil,
      capabilities: .init(), maximumPasteBytes: 1024, layoutBudget: .init(nodeCapacity: 32, maximumBlockVisits: 128))
  }

  var tickInterval: Duration? { nil }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(.control(.c), _): return .quit
    case .key(let key, let modifiers):
      if key == .character("c") && modifiers.withoutLocks == .control { return .quit }
      if navigation.activeScope == .workspace, modifiers.withoutLocks.isEmpty {
        if key == .character("q") { return .quit }
        if key == .character("?") {
          if navigation.push(.help, focus: help.focus) { help.focus.requestFocus(.help) }
          return .redraw
        }
      }
      switch navigation.route(key, modifiers: modifiers, mode: .normal) {
      case .input: return .none
      case .consumed: return .redraw
      case .routed(let route): return apply(route)
      }
    case .mouse(let mouse):
      guard mouse.action == .press, mouse.button == .left, mouse.modifiers.isEmpty else { return .none }
      let changed = navigation.focus(column: mouse.column, row: mouse.row)
      return changed ? .redraw : .none
    default: return .none
    }
  }

  private func apply(_ route: NavigationRoute<Scope, Target>) -> ScreenUpdate {
    switch route {
    case .focusChanged: return .redraw
    case .blocked: return .none
    case .action(.help, _, let intent):
      switch intent {
      case .back, .activate: _ = navigation.pop()
      case .move(let direction): help.move(direction)
      case .focus: break
      }
    case .action(.workspace, let target, let intent):
      switch intent {
      case .move(let direction):
        if target == .notes { workspace.moveSelection(direction) }
        if target == .reader { workspace.scroll(direction) }
      case .activate:
        if target == .notes { _ = navigation.focus(.reader) }
      case .back:
        if target == .reader { _ = navigation.focus(.notes) }
      case .focus: break
      }
    }
    return .redraw
  }

  func render(in size: TerminalSize) -> some Block {
    Overlay {
      if size.rows < 4 {
        Canvas(workspace)
      } else {
        Column {
          Text("SLATE / SCOPED NAVIGATION", style: Style(foreground: .cyan, bold: true))
          Canvas(workspace).frame(width: .fill, height: .fill)
          Text("hjkl Move | Ctrl-hjkl Focus | Enter Open | Esc Back | ? Help | q Quit", style: Style(dim: true))
          Text("Legacy terminal: Ctrl-W then hjkl changes focus", style: Style(dim: true))
        }.frame(width: .fill, height: .fill)
      }
      if navigation.activeScope == .help {
        Canvas(help).frame(width: .fixed(min(52, size.columns)), height: .fixed(min(11, size.rows)))
          .position(column: max(0, (size.columns - 52) / 2), row: max(0, (size.rows - 11) / 2))
      }
    }
  }
}

final class NotesDrawing: CanvasDrawing {
  let focus: FocusState<SlateScopedNavigationDemo.Target>
  private(set) var selected = 0
  private(set) var scrollLine = 0

  init(focus: FocusState<SlateScopedNavigationDemo.Target>) { self.focus = focus }

  func moveSelection(_ direction: FocusDirection) {
    let previous = selected
    if direction == .down { selected = min(2, selected + 1) }
    if direction == .up { selected = max(0, selected - 1) }
    if previous != selected { scrollLine = 0 }
  }

  func scroll(_ direction: FocusDirection) {
    if direction == .down { scrollLine = min(7, scrollLine + 1) }
    if direction == .up { scrollLine = max(0, scrollLine - 1) }
  }

  private func panes(in area: Rect) -> (notes: Rect, reader: Rect) {
    if area.width >= 60 {
      let width = min(28, area.width / 3)
      return (
        Rect(x: 0, y: 0, width: width, height: area.height),
        Rect(x: width + 1, y: 0, width: area.width - width - 1, height: area.height)
      )
    }
    let empty = Rect(x: 0, y: 0, width: 0, height: 0)
    return focus.isFocused(.reader) ? (empty, area) : (area, empty)
  }

  func layout(in regions: inout CanvasLayout) throws(LayoutError) {
    let panes = panes(in: regions.area)
    try regions.focusTarget(
      .notes, in: focus, bounds: panes.notes, enabled: true,
      visibility: panes.notes.isEmpty ? .collapsed : .visible,
      neighbors: .init(left: nil, right: .reader, up: nil, down: nil))
    try regions.focusTarget(
      .reader, in: focus, bounds: panes.reader, enabled: true,
      visibility: panes.reader.isEmpty ? .collapsed : .visible,
      neighbors: .init(left: .notes, right: nil, up: nil, down: nil))
  }

  func paint(in frame: inout Frame) {
    let panes = panes(in: frame.area)
    frame.border(panes.notes, title: " Notes ", style: Style(foreground: focus.isFocused(.notes) ? .cyan : .white))
    frame.border(panes.reader, title: " Reader ", style: Style(foreground: focus.isFocused(.reader) ? .cyan : .white))
    let list = panes.notes.inset(horizontal: 1, vertical: 1)
    for index in 0..<min(3, list.height) {
      let title = index == 0 ? "Morning plan" : index == 1 ? "Walk notes" : "Reading list"
      frame.text(
        title, in: Rect(x: list.x, y: list.y + index, width: list.width, height: 1),
        style: Style(foreground: index == selected ? .cyan : .white, underlined: index == selected))
    }
    let reader = panes.reader.inset(horizontal: 1, vertical: 1)
    for row in 0..<min(8 - scrollLine, reader.height) {
      frame.text(
        readerLine(row + scrollLine), in: Rect(x: reader.x, y: reader.y + row, width: reader.width, height: 1),
        style: Style())
    }
  }

  private func readerLine(_ line: Int) -> String {
    switch line {
    case 0:
      selected == 0
        ? "Make room for the next idea." : selected == 1 ? "A few things seen along the way." : "Books to return to."
    case 1: ""
    case 2: "j/k moves inside the focused pane."
    case 3: "Ctrl-h/l changes the focused pane."
    case 4: "Selection stays in the notes list."
    case 5: "The reader keeps its scroll position."
    case 6: "? opens an isolated help dialog."
    default: "Escape returns without losing your place."
    }
  }
}

final class HelpDrawing: CanvasDrawing {
  let focus = FocusState<SlateScopedNavigationDemo.Target>(capacity: 1, initial: .help)
  private(set) var selected = 0

  func move(_ direction: FocusDirection) {
    if direction == .down { selected = min(2, selected + 1) }
    if direction == .up { selected = max(0, selected - 1) }
  }

  func layout(in regions: inout CanvasLayout) throws(LayoutError) {
    try regions.focusTarget(
      .help, in: focus, bounds: regions.area, enabled: true, visibility: .visible, neighbors: .automatic)
  }

  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: .black)))
    frame.border(frame.area, title: " Navigation help ", style: Style(foreground: .cyan))
    let inner = frame.area.inset(horizontal: 1, vertical: 1)
    for index in 0..<min(3, inner.height) {
      let text =
        index == 0
        ? "hjkl stays inside this dialog"
        : index == 1 ? "Ctrl-hjkl cannot reach behind it" : "Enter or Escape returns to your pane"
      frame.text(
        text, in: Rect(x: inner.x, y: inner.y + index, width: inner.width, height: 1),
        style: Style(foreground: selected == index ? .cyan : .white, underlined: selected == index))
    }
  }
}
