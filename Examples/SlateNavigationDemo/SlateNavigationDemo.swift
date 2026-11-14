import Slate
import SlateGamepad

/// A studio for exploring layout, spatial focus, text, color, and images.
/// All activity data and test runs are deterministic demo fixtures.
@main
struct SlateNavigationDemo: ~Copyable, ScreenApplication {
  let focus = FocusState<NavigationTarget>(capacity: 40, initial: .overview)
  let input = try! TextInput("Edit me", capacity: 128)
  let scratchpad = try! TextInput("A note that stays here", capacity: 128)
  let signal = StudioSignal()
  let spectrum = StudioSpectrum()
  let progressDrawing = StudioTestProgress()
  let sourceDrawing = StudioSourcePreview()
  let artwork = StudioArtwork()
  var page = NavigationPage.overview
  var guide = NavigationGuide.gettingStarted
  var scene = GalleryScene.aurora
  var layoutSuite = true
  var inputSuite = true
  var unicodeSuite = false
  var accent = Color.cyan
  var lightTheme = false
  var animating = true
  var runningTests = false
  var testProgress = 0
  var testCount = 0
  var editing = false
  var lastAction = "Welcome to Slate Studio / choose a page to explore"
  var graphicsSupport = GallerySupport.probing
  var usesKitty = true
  var images: StudioImages?
  var uploadedImages: UInt8 = 0
  var placedImageID: UInt32?
  private var pageNeedsLayout = false
  private var deferredDirection: FocusDirection?
  var controllerEnabled = CommandLine.arguments.contains("--controller")
  private var gamepad = Gamepad()
  private var animationElapsed = Duration.zero

  var palette: StudioPalette { StudioPalette(light: lightTheme) }
  static var configuration: ScreenApplicationConfiguration {
    .init(
      mouseTracking: true, enhancedKeyboard: true, kittyGraphicsQueryID: graphicsQueryID,
      capabilities: .init(color: .trueColor, unicode: .grapheme))
  }
  var tickInterval: Duration? {
    if controllerEnabled { return .milliseconds(16) }
    return (page == .overview && animating) || runningTests ? .milliseconds(100) : nil
  }
  var hasPendingWork: Bool { deferredDirection != nil && !pageNeedsLayout }

  mutating func didPresentFrame(_ statistics: FrameStatistics) { pageNeedsLayout = false }

  mutating func performPendingWork() -> ScreenUpdate {
    guard !pageNeedsLayout, let direction = deferredDirection else { return .none }
    deferredDirection = nil
    return move(direction)
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .tick(let elapsed):
      var changed = pollController(copyBuffer: &copyBuffer)
      // Controller polling stays responsive without accelerating the animations.
      animationElapsed += elapsed
      guard animationElapsed >= .milliseconds(100) else { return changed ? .redraw : .none }
      animationElapsed = animationElapsed < .milliseconds(200) ? animationElapsed - .milliseconds(100) : .zero
      if page == .overview && animating {
        signal.phase = (signal.phase + 2) % 64
        changed = true
      }
      if runningTests {
        testProgress = min(100, testProgress + 5)
        if testProgress == 100 {
          runningTests = false
          lastAction = "Sample run complete / " + String(testCount) + " checks passed"
        }
        changed = true
      }
      return changed ? .redraw : .none
    case .kittyGraphicsReply(let reply):
      if reply.imageID == Self.graphicsQueryID && graphicsSupport == .probing {
        graphicsSupport = reply.isSuccess ? .supported : .unavailable
        return .redraw
      }
      if (4_200...4_202).contains(reply.imageID), !reply.isSuccess {
        graphicsSupport = .unavailable
        lastAction = "The terminal rejected the image / using cell graphics"
        return .redraw
      }
      return .none
    case .primaryDeviceAttributes:
      guard graphicsSupport == .probing else { return .none }
      graphicsSupport = .unavailable
      return .redraw
    case .key(let key, let modifiers): return handle(key, modifiers: modifiers, copyBuffer: &copyBuffer)
    case .mouse(let mouse):
      guard mouse.action == .press && mouse.button == .left else { return .none }
      let changed = focus.focus(column: mouse.column, row: mouse.row)
      deferredDirection = nil
      if changed { editing = false }
      let opened: Bool
      if let selected = focus.focusedID, let bounds = focus.bounds(for: selected),
        bounds.contains(column: mouse.column, row: mouse.row)
      {
        opened = openFocusedPage()
      } else {
        opened = false
      }
      return changed || opened ? .redraw : .none
    case .paste(let text):
      guard editing, let field = editingInput else { return .none }
      do throws(TextInputError) { try field.insert(text) } catch {
        lastAction = "Input rejected (maximum 128 UTF-8 bytes)"
      }
      return .redraw
    default: return .none
    }
  }

  private mutating func pollController(copyBuffer: inout CopyBuffer) -> Bool {
    guard controllerEnabled else { return false }
    let previousStatus = gamepad.status
    let actions = gamepad.poll(at: .now)
    var changed = previousStatus != gamepad.status
    for index in 0..<actions.count {
      if handleController(actions[index], copyBuffer: &copyBuffer) == .redraw { changed = true }
    }
    return changed
  }

  mutating func handleController(_ action: GamepadAction, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch action {
    case .move(let direction):
      let key: InputKey
      switch direction {
      case .up: key = .up
      case .down: key = .down
      case .left: key = .left
      case .right: key = .right
      }
      return handle(key, modifiers: [], copyBuffer: &copyBuffer)
    case .activate: return handle(.enter, modifiers: [], copyBuffer: &copyBuffer)
    case .back:
      deferredDirection = nil
      if editing {
        editing = false
        lastAction = "Navigation mode"
      } else {
        let sidebar: NavigationTarget
        switch page {
        case .overview: sidebar = .overview
        case .sources: sidebar = .sources
        case .tests: sidebar = .tests
        case .docs: sidebar = .docs
        case .tools: sidebar = .tools
        case .gallery: sidebar = .gallery
        }
        _ = focus.focus(sidebar)
        lastAction = "Choose a page with the D-pad or left stick"
      }
      return .redraw
    case .pause:
      guard page == .overview && !editing else { return .none }
      animating.toggle()
      return .redraw
    }
  }

  private var controllerHint: String {
    switch gamepad.status {
    case .connected: return "PAD / D-pad or stick focus / Cross explore / Circle back / Square pause"
    case .disconnected: return "PAD / waiting for a controller"
    case .permissionDenied: return "PAD / input device access denied / see README"
    case .unavailable: return "PAD / device unavailable / retrying"
    }
  }

  private mutating func handle(_ key: InputKey, modifiers: KeyModifiers, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    let modifiers = modifiers.withoutLocks
    if key == .control(.q) || (key == .character("q") && modifiers == .control) { return .quit }
    if editing && editingInput == nil { editing = false }
    if editing, let field = editingInput {
      if key == .escape || key == .enter {
        editing = false
        lastAction = "Navigation mode"
        return .redraw
      }
      switch field.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) {
      case .changed: return .redraw
      case .rejected:
        lastAction = "Input rejected (maximum 128 UTF-8 bytes)"
        return .redraw
      case .ignored, .submit: return .none
      }
    }
    if key == .control(.c) || (key == .character("c") && modifiers == .control) { return .quit }
    guard modifiers.isEmpty else { return .none }
    let direction: FocusDirection
    switch key {
    case .left: direction = .left
    case .right: direction = .right
    case .up: direction = .up
    case .down: direction = .down
    case .enter: return activate()
    case .character(" ") where page == .overview:
      animating.toggle()
      return .redraw
    case .character("q"), .escape: return .quit
    default: return .none
    }
    // A page's new focus geometry commits with its next successful frame.
    if pageNeedsLayout || deferredDirection != nil {
      deferredDirection = direction
      return .redraw
    }
    return move(direction)
  }

  private var editingInput: TextInput? {
    if page == .sources && focus.isFocused(.input) { return input }
    if page == .tools && focus.isFocused(.scratchpad) { return scratchpad }
    return nil
  }

  private mutating func move(_ direction: FocusDirection) -> ScreenUpdate {
    lastAction = focus.move(direction) ? "Enter explores the focused control" : "Edge of the available targets"
    return .redraw
  }

  private mutating func openFocusedPage() -> Bool {
    guard let next = focus.focusedID?.page, next != page else { return false }
    page = next
    editing = false
    deferredDirection = nil
    pageNeedsLayout = true
    lastAction = "Opened " + next.title
    return true
  }

  private mutating func activate() -> ScreenUpdate {
    guard let selected = focus.focusedID else { return .none }
    if selected.page != nil {
      _ = openFocusedPage()
      return .redraw
    }
    if editingInput != nil {
      editing = true
      lastAction = "Editing: arrows move the caret; Escape returns"
      return .redraw
    }
    switch selected {
    case .waveMetric: signal.mode = .wave
    case .barsMetric: signal.mode = .bars
    case .heatMetric: signal.mode = .heatmap
    case .signal: signal.mode = signal.mode == .wave ? .bars : signal.mode == .bars ? .heatmap : .wave
    case .pauseAnimation: animating.toggle()
    case .shuffleSignal: signal.phase = (signal.phase + 19) % 64
    case .exploreGallery:
      _ = focus.focus(.gallery)
      _ = openFocusedPage()
      return .redraw
    case .layout, .drawing, .output, .text, .images: sourceDrawing.selected = selected
    case .sourcePreview: sourceDrawing.selected = sourceDrawing.selected == .layout ? .drawing : .layout
    case .build:
      lastAction = "Sample build / 6 modules compiled / zero warnings"
      return .redraw
    case .run:
      lastAction = "Activated Run"
      return .redraw
    case .layoutSuite: layoutSuite.toggle()
    case .inputSuite: inputSuite.toggle()
    case .unicodeSuite: unicodeSuite.toggle()
    case .selectAllSuites:
      layoutSuite = true
      inputSuite = true
      unicodeSuite = true
    case .clearSuites:
      layoutSuite = false
      inputSuite = false
      unicodeSuite = false
    case .runSuites:
      testCount = (layoutSuite ? 88 : 0) + (inputSuite ? 61 : 0) + (unicodeSuite ? 54 : 0)
      guard testCount > 0 else {
        lastAction = "Choose at least one suite for the sample run"
        return .redraw
      }
      testProgress = 0
      runningTests = true
    case .gettingStarted: guide = .gettingStarted
    case .layoutGuide: guide = .layout
    case .inputGuide: guide = .input
    case .cyanAccent: accent = .cyan
    case .greenAccent: accent = .green
    case .magentaAccent: accent = .magenta
    case .amberAccent: accent = StudioPalette.amber
    case .coralAccent: accent = StudioPalette.coral
    case .blueAccent: accent = StudioPalette.sky
    case .spectrum: spectrum.shift = (spectrum.shift + 37) % 256
    case .toggleTheme: lightTheme.toggle()
    case .resetTools:
      accent = .cyan
      lightTheme = false
      spectrum.shift = 0
      scratchpad.selectAll()
      try! scratchpad.insert("A note that stays here".utf8Span)
    case .aurora: scene = .aurora
    case .orbit: scene = .orbit
    case .dunes: scene = .dunes
    case .artwork: scene = GalleryScene(rawValue: (scene.rawValue + 1) % 3)!
    case .toggleKitty: usesKitty.toggle()
    default: break
    }
    lastAction = "Activated " + label(selected)
    return .redraw
  }

  func render(in size: TerminalSize) -> some Block {
    signal.palette = palette
    sourceDrawing.palette = palette
    progressDrawing.palette = palette
    progressDrawing.progress = testProgress
    progressDrawing.running = runningTests
    artwork.scene = scene
    artwork.showsCells = !usesKitty || graphicsSupport != .supported
    artwork.background = palette.panel
    return Column(gap: 1) {
      Column {
        Row {
          Text("◆ SLATE STUDIO", style: Style(foreground: accent, background: palette.background, bold: true))
            .frame(width: .fill, alignment: .topLeading)
          Text(page.title + " / EXPLORE", style: Style(foreground: palette.muted, background: palette.background))
        }
        Canvas(spectrum).frame(width: .fill, height: .fixed(1))
      }
      if size.columns >= 54 {
        Row(gap: 2) {
          sidebar(compact: false).frame(width: .fixed(18), height: .fill)
          pageContent.frame(width: .fill, height: .fill)
        }.frame(width: .fill, height: .fill)
      } else {
        Column(gap: 1) {
          sidebar(compact: true)
          pageContent.frame(width: .fill, height: .fill)
        }.frame(width: .fill, height: .fill)
      }
      Column {
        Text(lastAction, style: Style(foreground: palette.muted, background: palette.background))
        if controllerEnabled {
          Text(controllerHint, style: Style(foreground: accent, background: palette.background))
        }
        Text(
          editing ? "EDIT / Esc navigate / Ctrl-Q quit" : "↑↓←→ focus / Enter explore / Q quit",
          style: Style(foreground: palette.text, background: palette.background))
      }
    }.padding(1).background(palette.background)
  }
}
