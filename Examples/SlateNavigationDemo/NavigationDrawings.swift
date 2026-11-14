import Slate

enum SignalMode { case wave, bars, heatmap }

/// Reuses the same drawing owners as focus and page state change.
final class StudioSignal: CanvasDrawing, ~Sendable {
  var phase = 0
  var mode = SignalMode.wave
  var palette = StudioPalette()

  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: palette.panel)))
    let width = frame.area.width
    let height = frame.area.height
    guard width > 0 && height > 0 else { return }
    for x in 0..<width {
      let level = 32 - abs((x * 3 + phase) % 64 - 32)
      for y in 0..<height {
        let color: Color
        switch mode {
        case .wave:
          let wave = level * max(0, height - 1) / 32
          if y == height - 1 - wave {
            frame[x, y] = Cell(Glyph("●")!, style: Style(foreground: StudioPalette.mint, background: palette.panel))
            continue
          }
          color = y > height - 1 - wave ? .rgb(20, 70, 72) : palette.panel
        case .bars:
          let bar = x * 14 / max(1, width)
          let amplitude = 32 - abs((bar * 9 + phase) % 64 - 32)
          let filled = max(1, amplitude * height / 32)
          color =
            y >= height - filled && x % max(2, width / 14) != 0
            ? .rgb(UInt8(70 + bar * 9), UInt8(205 - bar * 5), 245) : palette.panel
        case .heatmap:
          let value = (x * 5 + y * 17 + phase * 3) % 128
          color = .rgb(UInt8(35 + value), UInt8(45 + value / 2), UInt8(100 + value))
        }
        frame[x, y] = Cell(style: Style(background: color))
      }
    }
  }
}

final class StudioSpectrum: CanvasDrawing, ~Sendable {
  var shift = 0

  func paint(in frame: inout Frame) {
    let width = max(1, frame.area.width - 1)
    for x in 0..<frame.area.width {
      let value = (x * 255 / width + shift) % 256
      for y in 0..<frame.area.height {
        let fade = y * 80 / max(1, frame.area.height)
        frame[x, y] = Cell(
          style: Style(
            background: .rgb(
              UInt8(max(0, value - fade)), UInt8(max(0, 220 - abs(value - 128) - fade)),
              UInt8(max(0, 255 - value / 2 - fade)))))
      }
    }
  }
}

final class StudioTestProgress: CanvasDrawing, ~Sendable {
  var progress = 0
  var running = false
  var palette = StudioPalette()

  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: palette.panel)))
    let completed = progress * frame.area.width / 100
    if frame.area.height > 0 {
      for x in 0..<frame.area.width {
        frame[x, 0] = Cell(
          Glyph("━")!,
          style: Style(
            foreground: x < completed ? StudioPalette.mint : palette.border, background: palette.panel))
      }
    }
    let title =
      running
      ? "Running sample checks…" : progress == 100 ? "All selected checks passed" : "Ready / select suites above"
    frame.text(
      title, in: Rect(y: min(1, frame.area.height), width: frame.area.width, height: max(0, frame.area.height - 1)),
      style: Style(foreground: running ? StudioPalette.amber : StudioPalette.mint, background: palette.panel))
  }
}

final class StudioSourcePreview: CanvasDrawing, ~Sendable {
  var selected = NavigationTarget.layout
  var palette = StudioPalette()

  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: palette.panel)))
    let first: String
    let second: String
    switch selected {
    case .drawing:
      first = "func paint(in frame: inout Frame) {"
      second = "  frame.fill(frame.area, with: pixel)"
    case .output:
      first = "let output = try Output()"
      second = "try screen.draw(size: size, to: output)"
    case .text:
      first = "Text(\"Hello, terminal ✨\")"
      second = "  .padding(1).border(\"Welcome\")"
    case .images:
      first = "try output.uploadKittyImage(image, id: 1)"
      second = "try output.placeKittyImage(id: 1, in: rect)"
    default:
      first = "Row(gap: 1) {"
      second = "  sidebar; content.navigationGroup(in: focus)"
    }
    frame.text(
      first, in: Rect(width: frame.area.width, height: min(1, frame.area.height)),
      style: Style(foreground: StudioPalette.lilac, background: palette.panel))
    if frame.area.height > 1 {
      frame.text(
        second, in: Rect(y: 1, width: frame.area.width, height: 1),
        style: Style(foreground: StudioPalette.sky, background: palette.panel))
    }
  }
}
