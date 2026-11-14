import Slate
import SlateGamepad

/// Fixed diagnostic records and one inline snapshot; no per-frame formatting,
/// strings, queues, or retained input events. Two columns fit an 80x24 terminal.
final class KeyboardControlsDrawing: CanvasDrawing, ~Sendable {
  struct Control {
    let button: GamepadButtons
    let label: String
    let action: String
  }
  static let controls: InlineArray<19, Control> = [
    .init(button: .up, label: "D-pad up", action: "right wheel north"),
    .init(button: .down, label: "D-pad down", action: "right wheel south"),
    .init(button: .left, label: "D-pad left", action: "previous tab"),
    .init(button: .right, label: "D-pad right", action: "next tab"),
    .init(button: .cross, label: "Cross", action: "accept / space"),
    .init(button: .circle, label: "Circle", action: "cancel pending"),
    .init(button: .square, label: "Square", action: "delete character"),
    .init(button: .triangle, label: "Triangle", action: "period + space"),
    .init(button: .l1, label: "L1", action: "toggle capitals"),
    .init(button: .r1, label: "R1", action: "hold extra letters"),
    .init(button: .l2, label: "L2", action: "delete word"),
    .init(button: .r2, label: "R2", action: "accept / space"),
    .init(button: .l3, label: "L3", action: "cancel pending"),
    .init(button: .r3, label: "R3", action: "accept / space"),
    .init(button: .options, label: "Options", action: "controls / return"),
    .init(button: .create, label: "Create", action: "copy draft"),
    .init(button: .ps, label: "PS", action: "home tab"),
    .init(button: .touchpad, label: "Touch click", action: "pause / resume"),
    .init(button: .microphoneMute, label: "Mic mute", action: "system audio")
  ]
  var snapshot = GamepadState()
  var scrollOffset = 0

  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: KeyboardTheme.panel)))
    let columns = frame.area.width >= 74 ? 2 : 1
    let rowCount = (Self.controls.count + columns - 1) / columns
    let rows = max(0, min(rowCount, frame.area.height - 5))
    let start = min(scrollOffset, max(0, rowCount - rows))
    let columnWidth = frame.area.width / columns
    for row in 0..<rows {
      for column in 0..<columns {
        let index = column * rowCount + start + row
        guard index < Self.controls.count else { continue }
        let item = Self.controls[index]
        let supported = snapshot.connected && snapshot.supportedButtons.contains(item.button)
        let pressed = snapshot.buttons.contains(item.button)
        let x = column * columnWidth
        let style = Style(
          foreground: pressed ? KeyboardTheme.accent : KeyboardTheme.text, background: KeyboardTheme.panel,
          bold: pressed)
        frame.text(pressed ? "*" : supported ? "-" : "?", in: Rect(x: x, y: row, width: 1, height: 1), style: style)
        frame.text(item.label, in: Rect(x: x + 2, y: row, width: 12, height: 1), style: style)
        frame.text(
          supported ? item.action : "not exposed",
          in: Rect(x: x + 15, y: row, width: max(0, columnWidth - 15), height: 1),
          style: Style(
            foreground: supported ? KeyboardTheme.muted : KeyboardTheme.accent, background: KeyboardTheme.panel))
      }
    }
    let detail = rows
    label("Left X/Y", x: 0, y: detail, frame: &frame)
    number(snapshot.leftX, x: 10, y: detail, frame: &frame)
    number(snapshot.leftY, x: 17, y: detail, frame: &frame)
    label("Right X/Y", x: 27, y: detail, frame: &frame)
    if snapshot.features.contains(.rightStick) {
      number(snapshot.rightX, x: 38, y: detail, frame: &frame)
      number(snapshot.rightY, x: 45, y: detail, frame: &frame)
    } else {
      label("n/a", x: 38, y: detail, frame: &frame)
    }
    label("L2 / R2", x: 0, y: detail + 1, frame: &frame)
    if snapshot.supportedButtons.contains(.l2) {
      number(snapshot.leftTrigger, x: 10, y: detail + 1, frame: &frame)
    } else {
      label("n/a", x: 10, y: detail + 1, frame: &frame)
    }
    if snapshot.supportedButtons.contains(.r2) {
      number(snapshot.rightTrigger, x: 17, y: detail + 1, frame: &frame)
    } else {
      label("n/a", x: 17, y: detail + 1, frame: &frame)
    }
    touch(snapshot.primaryTouch, label: "Touch 1", row: detail + 2, frame: &frame)
    touch(snapshot.secondaryTouch, label: "Touch 2", row: detail + 3, frame: &frame)
    label("* pressed / - released / ? not exposed / D-pad up/down scroll", x: 0, y: detail + 4, frame: &frame)
  }
  private func touch(_ touch: GamepadTouch, label name: String, row: Int, frame: inout Frame) {
    label(name, x: 0, y: row, frame: &frame)
    guard snapshot.features.contains(.touchPositions) else {
      label("not exposed", x: 10, y: row, frame: &frame)
      return
    }
    number(touch.x, x: 10, y: row, frame: &frame)
    number(touch.y, x: 17, y: row, frame: &frame)
    let status: String
    switch touch.isTouching {
    case true: status = "finger down"
    case false: status = "finger up"
    case nil: status = "contact state unavailable"
    }
    label(status, x: 27, y: row, frame: &frame)
  }
  private func label(_ text: String, x: Int, y: Int, frame: inout Frame) {
    frame.text(
      text, in: Rect(x: x, y: y, width: max(0, frame.area.width - x), height: 1),
      style: Style(foreground: KeyboardTheme.muted, background: KeyboardTheme.panel))
  }
  private func number(_ value: Float, x: Int, y: Int, frame: inout Frame) {
    guard value.isFinite else {
      label("n/a", x: x, y: y, frame: &frame)
      return
    }
    let integer = Int((max(-1, min(1, value)) * 100).rounded())
    let magnitude = abs(integer)
    let bytes: InlineArray<5, UInt8> = [
      integer < 0 ? 45 : 43, UInt8(magnitude / 100) + 48, 46, UInt8(magnitude / 10 % 10) + 48,
      UInt8(magnitude % 10) + 48
    ]
    for index in 0..<5 where x + index >= 0 && x + index < frame.area.width && y >= 0 && y < frame.area.height {
      frame[x + index, y] = Cell(
        Glyph(Unicode.Scalar(bytes[index]))!,
        style: Style(foreground: KeyboardTheme.accent, background: KeyboardTheme.panel))
    }
  }
}
