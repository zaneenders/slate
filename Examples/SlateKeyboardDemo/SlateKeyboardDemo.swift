import Slate
import SlateGamepad

/// One chord keyboard: choose a letter group, then one of its four positions.
@main
struct SlateKeyboardDemo: ~Copyable, ScreenApplication {
  enum Target: Hashable {
    case group(Int)
    case letter(Int)
  }
  let draft = try! TextInput(capacity: 512)
  let hits = HitMap<Target>(capacity: 12)
  var selectedGroup: Int?
  var capitals = false
  var controllerEnabled = !CommandLine.arguments.contains("--keyboard-only")
  private var gamepad = Gamepad(captureSystemButtons: true)
  private var leftStick = StickFlick(eightWay: true)
  private var rightStick = StickFlick(eightWay: false)
  private var latchedGroup: Int?
  private var armed = false
  private var previousButtons: GamepadButtons = []
  private(set) var connected = false

  init() { precondition(KeyboardLetters.groups.count == 8) }
  static var configuration: ScreenApplicationConfiguration {
    .init(mouseTracking: true, enhancedKeyboard: true, capabilities: .init(color: .trueColor))
  }
  var tickInterval: Duration? { controllerEnabled ? .milliseconds(16) : nil }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .tick:
      return controllerEnabled ? receiveController(gamepad.sample(at: .now), copyBuffer: &copyBuffer) : .none
    case .key(let key, let modifiers):
      let modifiers = modifiers.withoutLocks
      if key == .control(.q) || key == .character("q") && modifiers == .control { return .quit }
      if modifiers.isEmpty {
        switch key {
        case .character(let scalar) where (49...56).contains(scalar.value): selectedGroup = Int(scalar.value) - 49
        case .up: type(sector: 0, group: selectedGroup, copyBuffer: &copyBuffer)
        case .right: type(sector: 2, group: selectedGroup, copyBuffer: &copyBuffer)
        case .down: type(sector: 4, group: selectedGroup, copyBuffer: &copyBuffer)
        case .left: type(sector: 6, group: selectedGroup, copyBuffer: &copyBuffer)
        case .escape:
          selectedGroup = nil
          resetGestures()
        case .enter: type(32, copyBuffer: &copyBuffer)
        default: return draft.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) == .changed ? .redraw : .none
        }
        return .redraw
      }
      return draft.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) == .changed ? .redraw : .none
    case .mouse(let mouse):
      guard mouse.action == .press && mouse.button == .left, let hit = hits.hitTest(mouse) else { return .none }
      switch hit.id {
      case .group(let group): selectedGroup = group
      case .letter(let sector): type(sector: sector, group: selectedGroup, copyBuffer: &copyBuffer)
      }
      return .redraw
    case .paste(let text):
      try? draft.insert(text)
      return .redraw
    default: return .none
    }
  }

  mutating func receiveController(_ state: GamepadState, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    let changed = connected != state.connected
    connected = state.connected
    guard connected else {
      guard changed else { return .none }
      armed = false
      previousButtons = []
      selectedGroup = nil
      resetGestures()
      return .redraw
    }
    guard armed else {
      if state.isNeutral {
        armed = true
        _ = leftStick.update(x: 0, y: 0)
        _ = rightStick.update(x: 0, y: 0)
      }
      return changed ? .redraw : .none
    }
    let pressed = state.buttons.subtracting(previousButtons)
    previousButtons = state.buttons
    if !pressed.intersection([.east, .west, .south, .leftShoulder, .create]).isEmpty {
      if pressed.contains(.east) {
        selectedGroup = nil
      } else if pressed.contains(.west) {
        _ = draft.handle(.backspace, copyBuffer: &copyBuffer)
      } else if pressed.contains(.south) {
        type(32, copyBuffer: &copyBuffer)
      } else if pressed.contains(.leftShoulder) {
        capitals.toggle()
      } else {
        draft.withText { copyBuffer.copy($0) }
      }
      resetGestures()
      return .redraw
    }
    let previousGroup = selectedGroup
    let previousRight = rightStick.active
    _ = leftStick.update(x: state.leftX, y: state.leftY)
    if let group = leftStick.active { selectedGroup = group }
    let letter = rightStick.update(x: state.rightX, y: state.rightY)
    if previousRight == nil && rightStick.active != nil { latchedGroup = selectedGroup }
    if let letter {
      type(sector: letter, group: latchedGroup, copyBuffer: &copyBuffer)
      latchedGroup = nil
    }
    return changed || previousGroup != selectedGroup || previousRight != rightStick.active || letter != nil
      ? .redraw : .none
  }

  private mutating func resetGestures() {
    leftStick.reset()
    rightStick.reset()
    latchedGroup = nil
  }
  private func type(sector: Int, group: Int?, copyBuffer: inout CopyBuffer) {
    guard let group, let byte = KeyboardLetters.letter(group: group, sector: sector) else { return }
    type(capitals ? byte - 32 : byte, copyBuffer: &copyBuffer)
  }
  private func type(_ byte: UInt8, copyBuffer: inout CopyBuffer) {
    // Controller letters and spaces are one byte. Reject before the throwing
    // insert path so a full draft does not allocate an error on every gesture.
    guard draft.byteCount - draft.selection.count < draft.capacity else { return }
    _ = draft.handle(.character(Unicode.Scalar(byte)), copyBuffer: &copyBuffer)
  }
  private func groupButton(_ group: Int) -> some Block {
    Text(
      KeyboardLetters.groups[group],
      style: Style(
        foreground: selectedGroup == group ? .black : .white,
        background: selectedGroup == group ? .cyan : .default)
    )
    .padding(horizontal: 1).frame(width: .fill).hitRegion(.group(group), in: hits)
  }
  func render(in size: TerminalSize) -> some Block {
    Column(gap: 1) {
      Text("SLATE / CHORD KEYBOARD", style: Style(foreground: .cyan, bold: true))
      Text(controllerEnabled ? (connected ? "Controller connected" : "Waiting for controller") : "Keyboard / mouse")
      InputBox(draft, focused: true).border("Draft / 512 UTF-8 bytes")
      Text("Left stick or 1-8 selects a group; release the right stick to type")
      Row {
        groupButton(0)
        groupButton(1)
        groupButton(2)
        groupButton(3)
      }
      Row {
        groupButton(4)
        groupButton(5)
        groupButton(6)
        groupButton(7)
      }
      Row(gap: 1) {
        Text("Up: first").hitRegion(.letter(0), in: hits)
        Text("Right: second").hitRegion(.letter(2), in: hits)
        Text("Down: third").hitRegion(.letter(4), in: hits)
        Text("Left: fourth").hitRegion(.letter(6), in: hits)
      }
      Text(capitals ? "CAPS" : "abc")
      Text("Cross space / Square delete / Circle cancel / L1 caps / Create copy")
      Text("Keyboard: arrows choose letters / Enter space / Esc cancel / Ctrl-Q quits")
    }.padding(1)
  }
}
