import Slate
import SlateGamepad

@main
struct SlateKeyboardDemo: ~Copyable, ScreenApplication {
  let predictive: KeyboardSession
  let common: KeyboardSession
  let chords: KeyboardSession
  let leftDrawing: KeyboardWheelDrawing
  let rightDrawing: KeyboardWheelDrawing
  let draftDrawing: KeyboardDraftDrawing
  let controlsDrawing = KeyboardControlsDrawing()
  let hits = HitMap<KeyboardHit>(capacity: 24)
  var mode = KeyboardMode.predictive
  var controllerEnabled = !CommandLine.arguments.contains("--keyboard-only")
  private var gamepad = Gamepad(captureSystemButtons: true)
  private(set) var controllerStatus = GamepadStatus.disconnected
  private var leftStick = StickFlick(eightWay: true)
  private var rightStick = StickFlick(eightWay: false)
  private var rightGroup: Int?
  private var inputArmed = false
  private var previousButtons: GamepadButtons = []
  private var keyboardMore = false
  var showsControls = CommandLine.arguments.contains("--controls")
  var inputPaused = false
  private var copySource: KeyboardSession?
  var hasCopyRequest: Bool { copySource != nil }

  init() {
    KeyboardLetters.prepare()
    let lexicon = KeyboardLexicon()
    predictive = KeyboardSession(mode: .predictive, lexicon: lexicon)
    common = KeyboardSession(mode: .common, lexicon: lexicon)
    chords = KeyboardSession(mode: .chords, lexicon: lexicon)
    leftDrawing = KeyboardWheelDrawing(session: predictive, right: false)
    rightDrawing = KeyboardWheelDrawing(session: predictive, right: true)
    draftDrawing = KeyboardDraftDrawing(session: predictive)
  }
  var session: KeyboardSession {
    switch mode {
    case .predictive: predictive
    case .common: common
    case .chords: chords
    }
  }
  static var configuration: ScreenApplicationConfiguration {
    .init(mouseTracking: true, enhancedKeyboard: true, capabilities: .init(color: .trueColor))
  }
  var tickInterval: Duration? { controllerEnabled ? .milliseconds(16) : nil }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .tick:
      guard controllerEnabled else { return .none }
      let old = controllerStatus
      let update = receiveController(gamepad.sample(at: .now))
      fulfillCopyRequest(into: &copyBuffer)
      controllerStatus = gamepad.status
      return update == .redraw || old != controllerStatus ? .redraw : .none
    case .key(let key, let modifiers):
      let modifiers = modifiers.withoutLocks
      if key == .control(.q) || key == .control(.c)
        || modifiers == .control && (key == .character("q") || key == .character("c"))
      {
        return .quit
      }
      guard modifiers.isEmpty else { return .none }
      if key == .character("h") || key == .function(.f4) {
        showsControls.toggle()
        resetGestures()
        return .redraw
      }
      if showsControls {
        if key == .escape {
          showsControls = false
          resetGestures()
        } else if key == .down {
          controlsDrawing.scrollOffset = min(18, controlsDrawing.scrollOffset + 1)
        } else if key == .up {
          controlsDrawing.scrollOffset = max(0, controlsDrawing.scrollOffset - 1)
        }
        return .redraw
      }
      if key == .character("p") {
        inputPaused.toggle()
        resetGestures()
        return .redraw
      }
      if key == .character("y") {
        copySource = session
        fulfillCopyRequest(into: &copyBuffer)
        return .redraw
      }
      guard !inputPaused else { return .none }
      switch key {
      case .tab: switchTo(KeyboardMode(rawValue: (mode.rawValue + 1) % 3)!)
      case .function(.f1): switchTo(.predictive)
      case .function(.f2): switchTo(.common)
      case .function(.f3): switchTo(.chords)
      case .enter, .character(" "):
        session.finish()
        resetGestures()
      case .backspace:
        session.delete()
        resetGestures()
      case .escape:
        session.cancel()
        resetGestures()
      case .character("."):
        session.finish(period: true)
        resetGestures()
      case .character("c"): session.capitals.toggle()
      case .character("m") where mode == .common:
        keyboardMore.toggle()
        session.moreLetters = keyboardMore
        resetGestures()
      case .up: chooseRight(0)
      case .right: chooseRight(2)
      case .down: chooseRight(4)
      case .left: chooseRight(6)
      case .character(let value) where (49...56).contains(value.value):
        chooseLeft(Int(value.value) - 49)
      default: return .none
      }
      return .redraw
    case .mouse(let mouse):
      guard mouse.action == .press && mouse.button == .left,
        let hit = hits.hitTest(mouse)
      else { return .none }
      if showsControls || inputPaused { return .none }
      switch hit.id {
      case .tab(let next): switchTo(next)
      case .candidate(let index):
        guard index < session.candidateCount else { return .none }
        session.selectedCandidate = index
      case .leftWheel, .rightWheel:
        guard
          let sector = KeyboardWheelGeometry.hit(
            column: hit.column, row: hit.row, width: hit.bounds.width, height: hit.bounds.height,
            right: hit.id == .rightWheel)
        else { return .none }
        if hit.id == .leftWheel { chooseLeft(sector) } else { chooseRight(sector) }
      case .accept:
        session.finish()
        resetGestures()
      case .delete:
        session.delete()
        resetGestures()
      case .cancel:
        session.cancel()
        resetGestures()
      case .caps: session.capitals.toggle()
      case .more:
        guard mode == .common else { return .none }
        keyboardMore.toggle()
        session.moreLetters = keyboardMore
        resetGestures()
      case .period:
        session.finish(period: true)
        resetGestures()
      }
      return .redraw
    default: return .none
    }
  }

  mutating func fulfillCopyRequest(into buffer: inout CopyBuffer) {
    guard let source = copySource else { return }
    source.draft.withText { buffer.copy($0) }
    source.notice = .copied
    copySource = nil
  }

  mutating func switchTo(_ next: KeyboardMode) {
    guard next != mode else { return }
    resetGestures()
    common.moreLetters = false
    keyboardMore = false
    mode = next
    session.selectedGroup = nil
    resetGestures()
  }
  private mutating func resetGestures() {
    leftStick.reset()
    rightStick.reset()
    rightGroup = nil
    session.leftPreview = nil
    session.rightPreview = nil
    session.latchedGroup = nil
  }

  /// Synthetic snapshots use this same path in tests. Reconnect, cancellation,
  /// layer/tab changes, and button commands require neutral sticks before typing.
  mutating func receiveController(_ state: GamepadState) -> ScreenUpdate {
    let snapshotChanged = controlsDrawing.snapshot != state
    controlsDrawing.snapshot = state
    guard state.connected else {
      let changed = inputArmed || session.leftPreview != nil || session.rightPreview != nil || session.moreLetters
      inputArmed = false
      previousButtons = []
      resetGestures()
      session.selectedGroup = nil
      common.moreLetters = keyboardMore
      return changed || showsControls && snapshotChanged ? .redraw : .none
    }
    guard inputArmed else {
      if state.isNeutral {
        inputArmed = true
        _ = leftStick.update(x: 0, y: 0)
        _ = rightStick.update(x: 0, y: 0)
      }
      return showsControls && snapshotChanged ? .redraw : .none
    }
    let pressed = state.buttons.subtracting(previousButtons)
    previousButtons = state.buttons
    if pressed.contains(.options) {
      showsControls.toggle()
      resetGestures()
      return .redraw
    }
    if showsControls {
      if pressed.contains(.up) { controlsDrawing.scrollOffset = max(0, controlsDrawing.scrollOffset - 1) }
      if pressed.contains(.down) { controlsDrawing.scrollOffset = min(18, controlsDrawing.scrollOffset + 1) }
      return snapshotChanged ? .redraw : .none
    }
    if pressed.contains(.touchpad) {
      inputPaused.toggle()
      resetGestures()
      return .redraw
    }
    if pressed.contains(.create) {
      copySource = session
      return .redraw
    }
    if pressed.contains(.ps) {
      switchTo(.predictive)
      resetGestures()
      return .redraw
    }
    guard !inputPaused else { return .none }
    if pressed.contains(.left) || pressed.contains(.right) {
      let delta = pressed.contains(.left) ? 2 : 1
      switchTo(KeyboardMode(rawValue: (mode.rawValue + delta) % 3)!)
      return .redraw
    }
    let more = mode == .common && (keyboardMore || state.buttons.contains(.rightShoulder))
    if session.moreLetters != more {
      session.moreLetters = more
      session.selectedGroup = nil
      resetGestures()
      return .redraw
    }
    if pressed.contains(.east) || pressed.contains(.l3) {
      session.cancel()
      resetGestures()
      return .redraw
    }
    if pressed.contains(.west) {
      session.delete()
      resetGestures()
      return .redraw
    }
    if pressed.contains(.l2) {
      session.deleteWord()
      resetGestures()
      return .redraw
    }
    if pressed.contains(.south) || pressed.contains(.r2) || pressed.contains(.r3) {
      session.finish()
      resetGestures()
      return .redraw
    }
    if pressed.contains(.north) {
      session.finish(period: true)
      resetGestures()
      return .redraw
    }
    var changed = false
    if pressed.contains(.leftShoulder) {
      session.capitals.toggle()
      changed = true
    }
    if pressed.contains(.up) || pressed.contains(.down) {
      chooseRight(pressed.contains(.up) ? 0 : 4)
      resetGestures()
      return .redraw
    }
    let oldLeft = leftStick.active
    let oldRight = rightStick.active
    let left = leftStick.update(x: state.leftX, y: state.leftY)
    if mode == .chords || mode == .common && more, let group = leftStick.active {
      session.selectedGroup = group
    }
    let right = rightStick.update(x: state.rightX, y: state.rightY)
    if oldRight == nil && rightStick.active != nil {
      rightGroup = session.selectedGroup
      session.latchedGroup = rightGroup
    }
    session.leftPreview = leftStick.active
    session.rightPreview = rightStick.active
    if let left {
      chooseLeft(left)
      changed = true
    }
    if let right {
      if mode == .predictive { chooseRight(right) } else { chooseRight(right, group: rightGroup) }
      rightGroup = nil
      session.latchedGroup = nil
      changed = true
    }
    return changed || oldLeft != leftStick.active || oldRight != rightStick.active ? .redraw : .none
  }

  func chooseLeft(_ sector: Int) {
    precondition((0..<8).contains(sector))
    switch mode {
    case .predictive: session.addGroup(sector)
    case .common where !session.moreLetters: session.type(KeyboardLetters.common[sector])
    case .common, .chords:
      session.selectedGroup = sector
      session.notice = .ready
    }
  }
  func chooseRight(_ sector: Int) { chooseRight(sector, group: session.selectedGroup) }
  private func chooseRight(_ sector: Int, group: Int?) {
    if mode == .predictive {
      switch sector {
      case 0: session.selectedCandidate = 0
      case 2: session.moveCandidate(1)
      case 4: session.selectedCandidate = max(0, session.candidateCount - 1)
      case 6: session.moveCandidate(-1)
      default: break
      }
      return
    }
    guard mode != .common || session.moreLetters, let group else {
      session.notice = .chooseGroup
      return
    }
    guard let byte = KeyboardLetters.letter(group: group, sector: sector, extras: mode == .common) else {
      session.notice = .invalidLetter
      return
    }
    session.type(byte)
  }

  private var statusText: String {
    if !controllerEnabled { return "Keyboard / mouse" }
    switch controllerStatus {
    case .connected: return "Controller connected"
    case .disconnected: return "Waiting for controller"
    case .permissionDenied: return "Input access denied"
    case .unavailable: return "Controller retrying"
    }
  }
  private func tab(_ next: KeyboardMode) -> some Block {
    Text(
      next.title,
      style: Style(
        foreground: next == mode ? KeyboardTheme.background : KeyboardTheme.muted,
        background: next == mode ? KeyboardTheme.accent : KeyboardTheme.panel, bold: next == mode)
    )
    .padding(horizontal: 1).frame(width: .fill).hitRegion(.tab(next), in: hits)
  }
  private func candidate(_ index: Int) -> some Block {
    Text(
      session.candidate(index),
      style: Style(
        foreground: index == session.selectedCandidate ? KeyboardTheme.accent : KeyboardTheme.muted,
        background: KeyboardTheme.background, underlined: index == session.selectedCandidate)
    )
    .frame(width: .fill).hitRegion(.candidate(index), in: hits)
  }
  func render(in size: TerminalSize) -> some Block {
    leftDrawing.session = session
    rightDrawing.session = session
    draftDrawing.session = session
    return Column {
      Row(gap: 1) {
        Text("ORBIT / KEYBOARD LAB", style: Style(foreground: KeyboardTheme.accent, bold: true))
          .frame(width: .fill, alignment: .topLeading)
        Text(session.capitals ? "CAPS" : "abc", style: Style(foreground: KeyboardTheme.accent))
        Text(statusText, style: Style(foreground: KeyboardTheme.muted))
      }
      Row(gap: 1) {
        tab(.predictive)
        tab(.common)
        tab(.chords)
      }
      if showsControls {
        Canvas(controlsDrawing).border(" DUALSENSE / LIVE CONTROL MAP ", style: Style(foreground: KeyboardTheme.accent))
          .frame(width: .fill, height: .fill)
        Text(
          "Options / H / Esc returns / typing suspended in this view", style: Style(foreground: KeyboardTheme.accent))
        Text(
          "PS may be reserved by the OS / Mic mute stays with system audio",
          style: Style(foreground: KeyboardTheme.muted))
      } else {
        Canvas(draftDrawing).border(" DRAFT / independent per tab ", style: Style(foreground: KeyboardTheme.muted))
          .frame(width: .fill, height: .fixed(4))
        Text(
          inputPaused ? "INPUT PAUSED / touchpad click or P resumes" : mode.instruction,
          style: Style(foreground: KeyboardTheme.text))
        Row(gap: 2) {
          Canvas(leftDrawing).hitRegion(.leftWheel, in: hits)
            .border(" LEFT STICK ", style: Style(foreground: KeyboardTheme.muted)).frame(width: .fill, height: .fill)
          if size.columns >= 62 {
            Canvas(rightDrawing).hitRegion(.rightWheel, in: hits)
              .border(" RIGHT STICK ", style: Style(foreground: KeyboardTheme.muted)).frame(width: .fill, height: .fill)
          }
        }.frame(width: .fill, height: .fill)
        if mode == .predictive {
          Row(gap: 1) {
            candidate(0)
            candidate(1)
            candidate(2)
            candidate(3)
            candidate(4)
          }
        } else {
          Text(
            session.capitals ? "CAPS ON / right arrows select N E S W" : "Caps off / right arrows select N E S W",
            style: Style(foreground: KeyboardTheme.accent))
        }
        Text(session.notice.text, style: Style(foreground: KeyboardTheme.muted))
        Row(gap: 1) {
          Text("Enter accept").hitRegion(.accept, in: hits)
          Text("Bksp delete").hitRegion(.delete, in: hits)
          Text("Esc cancel").hitRegion(.cancel, in: hits)
          Text("C caps").hitRegion(.caps, in: hits)
          Text("M more").hitRegion(.more, in: hits)
          Text(". period").hitRegion(.period, in: hits)
        }
        Text(
          "Options/H controls / Touchpad/P pause / Create/Y copy / L2 delete word",
          style: Style(foreground: KeyboardTheme.muted))
      }
      Text(
        "Tab or F1-F3 tabs / 1-8 left sectors / arrows right stick / Ctrl-Q quit",
        style: Style(foreground: KeyboardTheme.muted))
    }.padding(1).background(KeyboardTheme.background)
  }
}

enum KeyboardHit: Hashable {
  case tab(KeyboardMode)
  case candidate(Int)
  case leftWheel, rightWheel, accept, delete, cancel, caps, more, period
}
