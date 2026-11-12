import Slate

/// A small integration example: two startup-owned drawings, bounded layout, and
/// one animation step per 50 ms deadline. Late frames are dropped, never queued.
@main
struct SlateGraphicsDemo: ScreenApplication {
  private let gradient = GradientDrawing()
  private let bars = BarDrawing()
  private let panelDrag = PanelDrag()
  private var nextFrame: ContinuousClock.Instant
  private(set) var isPaused = false
  private(set) var showsOverlay = true

  init() { self.init(now: ContinuousClock().now) }
  init(now: ContinuousClock.Instant) { nextFrame = now.advanced(by: .milliseconds(50)) }

  static var configuration: ScreenApplicationConfiguration {
    .init(
      maximumSize: TerminalSize(columns: 240, rows: 80), nodeCapacity: 64, mouseTracking: true,
      capabilities: .init(color: .trueColor, unicode: .grapheme))
  }

  var animationPhase: Int { bars.phase }
  var overlayBounds: Rect { panelDrag.bounds }
  var isDraggingOverlay: Bool { panelDrag.isDragging }
  var hasPendingWork: Bool { isDue(at: ContinuousClock().now) }

  func isDue(at now: ContinuousClock.Instant) -> Bool { !isPaused && now >= nextFrame }

  mutating func performPendingWork() -> ScreenUpdate { advance(at: ContinuousClock().now) }

  mutating func advance(at now: ContinuousClock.Instant) -> ScreenUpdate {
    guard isDue(at: now) else { return .none }
    bars.advance()
    nextFrame = now.advanced(by: .milliseconds(50))
    return .redraw
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(let key, let modifiers): return handle(key, modifiers: modifiers)
    case .mouse(let mouse): return showsOverlay ? panelDrag.handle(mouse) : .none
    default: return .none
    }
  }

  private mutating func handle(_ key: InputKey, modifiers: KeyModifiers) -> ScreenUpdate {
    if key == .control(.c) || key == .control(.q) { return .quit }
    if modifiers == .control && (key == .character("c") || key == .character("q")) { return .quit }
    guard modifiers.isEmpty || modifiers == .shift else { return .none }
    switch key {
    case .character("q"), .character("Q"): return .quit
    case .character("o"), .character("O"):
      showsOverlay.toggle()
      panelDrag.cancel()
    case .escape:
      panelDrag.cancel()
      guard showsOverlay else { return .none }
      showsOverlay = false
    case .character(" "):
      isPaused.toggle()
      nextFrame = ContinuousClock().now.advanced(by: .milliseconds(50))
    default: return .none
    }
    return .redraw
  }

  func render(in size: TerminalSize) -> some Block {
    panelDrag.prepare(in: size)
    return Column(gap: 1) {
      Text("SLATE GRAPHICS", style: Palette.heading)
      Overlay(alignment: .center) {
        Column(gap: 1) {
          Canvas(gradient).border("RGB gradient", style: Palette.border)
            .frame(width: .fill, height: .fixed(5))
          Row(gap: 1) {
            Canvas(bars).border("Canvas / animation", style: Palette.border)
              .frame(width: .fill, height: .fill)
            if size.columns >= 70 {
              Column(gap: 1) {
                Text("Latin: é / CJK: 漢字", style: Palette.text)
                Text("Emoji: 👩🏽‍💻 🚀", style: Palette.text)
                Text("Lines: ─│┌┐└┘", style: Palette.text)
              }
              .padding(1).border("Unicode", style: Palette.border)
              .background(Palette.panel).frame(width: .fixed(28), height: .fill)
            }
          }.frame(width: .fill, height: .fill)
        }.frame(width: .fill, height: .fill)
        if showsOverlay {
          Column(gap: 1) {
            Text("Drag the title bar", style: Palette.heading)
            Text("O / Escape closes", style: Palette.text)
          }
          .padding(1).border("Overlay", style: Palette.border)
          .background(Palette.panel).frame(width: .fixed(PanelDrag.width), height: .fixed(PanelDrag.height))
          .position(column: panelDrag.column, row: panelDrag.row)
        }
      }.frame(width: .fill, height: .fill)
      Text(
        isPaused ? "PAUSED / SPACE resume / O overlay / Q quit" : "SPACE pause / O overlay / Q quit",
        style: Palette.text)
    }.padding(1).background(Palette.background)
  }
}

private enum Palette {
  static let background = Color.rgb(12, 16, 26)
  static let panel = Color.rgb(22, 30, 45)
  static let heading = Style(foreground: .rgb(230, 240, 255), bold: true)
  static let text = Style(foreground: .rgb(172, 192, 216))
  static let border = Style(foreground: .rgb(74, 108, 148))
}

private final class GradientDrawing: CanvasDrawing, ~Sendable {
  func paint(in frame: inout Frame) {
    let denominator = max(1, frame.area.width - 1)
    for column in 0..<frame.area.width {
      let level = column * 255 / denominator
      let color = Color.rgb(UInt8(level), UInt8(255 - level), UInt8(128 + level / 2))
      frame.fill(
        Rect(x: column, width: 1, height: frame.area.height),
        with: Cell(style: Style(background: color)))
    }
  }
}

private final class BarDrawing: CanvasDrawing, ~Sendable {
  private(set) var phase = 0

  func advance() { phase = (phase + 1) % 64 }

  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: Palette.panel)))
    let count = min(12, frame.area.width)
    guard count > 0 else { return }
    for bar in 0..<count {
      let left = bar * frame.area.width / count
      let right = (bar + 1) * frame.area.width / count
      let level = 32 - abs((phase + bar * 7) % 64 - 32)
      let height = max(1, level * frame.area.height / 32)
      let color = Color.rgb(UInt8(60 + bar * 14), UInt8(200 - bar * 8), 255)
      frame.fill(
        Rect(x: left, y: frame.area.height - height, width: max(1, right - left - 1), height: height),
        with: Cell(style: Style(background: color)))
    }
  }
}
