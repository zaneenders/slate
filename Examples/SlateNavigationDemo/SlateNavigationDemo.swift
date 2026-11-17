import Slate
import SlateGamepad

/// Spatial focus, explicit editing, and controller navigation over one layout.
@main
struct SlateNavigationDemo: ~Copyable, ScreenApplication {
  static func main() async {
    var application = Self()
    let session = ScreenSession(maximumOutputBytes: 4 * 1_048_576, taskCapacity: 0)
    await session.main(
      application: &application, inputFileDescriptor: 0, outputFileDescriptor: 1, signalHandling: .managed)
  }

  enum Target: Hashable { case cyan, magenta, pause, input }
  let focus = FocusState<Target>(capacity: 8, initial: .cyan)
  let input = try! TextInput("Edit me", capacity: 128)
  let drawing = NavigationDrawing()
  var editing = false
  var animating = true
  var controllerEnabled = CommandLine.arguments.contains("--controller")
  private var gamepad = Gamepad()
  private var elapsed = Duration.zero

  static var configuration: ScreenApplicationConfiguration {
    .init(mouseTracking: true, enhancedKeyboard: true, capabilities: .init(color: .trueColor))
  }
  var tickInterval: Duration? { controllerEnabled ? .milliseconds(16) : animating ? .milliseconds(100) : nil }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .tick(let duration):
      var changed = false
      if controllerEnabled {
        let actions = gamepad.poll(at: .now)
        for index in 0..<actions.count {
          if handleController(actions[index], copyBuffer: &copyBuffer) == .redraw { changed = true }
        }
      }
      elapsed += duration
      if animating && elapsed >= .milliseconds(100) {
        elapsed = .zero
        drawing.phase = (drawing.phase + 1) % 16
        changed = true
      }
      return changed ? .redraw : .none
    case .key(let key, let modifiers): return handle(key, modifiers: modifiers, copyBuffer: &copyBuffer)
    case .mouse(let mouse):
      guard mouse.action == .press && mouse.button == .left else { return .none }
      _ = focus.focus(column: mouse.column, row: mouse.row)
      guard let id = focus.focusedID, focus.bounds(for: id)?.contains(column: mouse.column, row: mouse.row) == true
      else {
        return .none
      }
      editing = false
      return activate()
    case .paste(let text):
      guard editing else { return .none }
      try? input.insert(text)
      return .redraw
    default: return .none
    }
  }

  mutating func handleController(_ action: GamepadAction, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch action {
    case .move(let direction):
      let key: InputKey
      switch direction {
      case .left: key = .left
      case .right: key = .right
      case .up: key = .up
      case .down: key = .down
      }
      return handle(key, modifiers: [], copyBuffer: &copyBuffer)
    case .activate: return activate()
    case .back:
      editing = false
      _ = focus.focus(.cyan)
    case .pause: animating.toggle()
    }
    return .redraw
  }

  private mutating func handle(_ key: InputKey, modifiers: KeyModifiers, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    let modifiers = modifiers.withoutLocks
    if key == .control(.q) || key == .character("q") && modifiers == .control { return .quit }
    if editing {
      if key == .enter || key == .escape {
        editing = false
        return .redraw
      }
      return input.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) == .changed ? .redraw : .none
    }
    if key == .control(.c) || key == .character("c") && modifiers == .control { return .quit }
    guard modifiers.isEmpty else { return .none }
    switch key {
    case .left: _ = focus.move(.left)
    case .right: _ = focus.move(.right)
    case .up: _ = focus.move(.up)
    case .down: _ = focus.move(.down)
    case .enter: return activate()
    case .character(" "): animating.toggle()
    case .character("q"), .escape: return .quit
    default: return .none
    }
    return .redraw
  }

  private mutating func activate() -> ScreenUpdate {
    if editing {
      editing = false
      return .redraw
    }
    switch focus.focusedID {
    case .cyan: drawing.color = .cyan
    case .magenta: drawing.color = .magenta
    case .pause: animating.toggle()
    case .input: editing = true
    case nil: return .none
    }
    return .redraw
  }

  private func button(_ title: String, _ id: Target) -> some Block {
    Text(
      title,
      style: Style(
        foreground: focus.isFocused(id) ? .black : .white,
        background: focus.isFocused(id) ? .cyan : .default)
    )
    .padding(horizontal: 1).frame(width: .fill, alignment: .topLeading).focusTarget(id, in: focus)
  }
  private var controls: some Block {
    Column(gap: 1) {
      button("Cyan", .cyan)
      button("Magenta", .magenta)
      button(animating ? "Pause" : "Resume", .pause)
    }.navigationGroup(in: focus).padding(1).border("Controls")
  }
  private var preview: some Block {
    Column(gap: 1) {
      InputBox(input, focused: editing).border("Enter to edit").focusTarget(.input, in: focus)
      Canvas(drawing).frame(width: .fill, height: .fill)
    }.navigationGroup(in: focus).padding(1).border("Preview").frame(width: .fill, height: .fill)
  }
  func render(in size: TerminalSize) -> some Block {
    Column(gap: 1) {
      Text("SLATE / SPATIAL NAVIGATION", style: Style(foreground: .cyan, bold: true))
      if size.columns >= 54 {
        Row(gap: 1) {
          controls.frame(width: .fixed(22), height: .fill)
          preview
        }.frame(width: .fill, height: .fill)
      } else {
        Column(gap: 1) {
          controls
          preview
        }.frame(width: .fill, height: .fill)
      }
      Text(editing ? "Editing / Enter or Esc returns" : "Arrows focus / Enter activates / Space pauses / Q quits")
      if controllerEnabled { Text("D-pad/stick focus / Cross activate / Circle back / Square pause") }
    }.padding(1)
  }
}

final class NavigationDrawing: CanvasDrawing, ~Sendable {
  var phase = 0
  var color = Color.cyan
  func paint(in frame: inout Frame) {
    for row in 0..<frame.area.height {
      let width = (row + phase) % 16 * frame.area.width / 15
      frame.fill(Rect(y: row, width: width, height: 1), with: Cell(style: Style(background: color)))
    }
  }
}
