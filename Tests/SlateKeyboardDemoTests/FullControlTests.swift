import Slate
import SlateGamepad
import Testing

@testable import SlateKeyboardDemo

@Test func keyboardFullControlBindingsAreEdgedAndCopyUsesTheCurrentDraft() {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  app.switchTo(.common)
  for byte in "hello world ".utf8 { app.common.type(byte) }
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .l2, leftTrigger: 1))
  #expect(app.common.draft.snapshot() == "hello ")
  _ = app.receiveController(.init(connected: true, buttons: .l2, leftTrigger: 1))
  #expect(app.common.draft.snapshot() == "hello ")
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .create))
  #expect(app.hasCopyRequest == true)
  var copy = CopyBuffer()
  app.fulfillCopyRequest(into: &copy)
  var copied = ""
  copy.flush { copied = String(copying: $0) }
  #expect(copied == "hello " && app.hasCopyRequest == false)
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .r2, rightTrigger: 1))
  #expect(app.common.draft.snapshot() == "hello  ")
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .r3))
  #expect(app.common.draft.snapshot() == "hello   ")
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .ps))
  #expect(app.mode == .predictive && app.common.draft.snapshot() == "hello   ")
  app.predictive.addGroup(0)
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .l3))
  #expect(app.predictive.tokenCount == 0)
}

@Test func keyboardControlMapMonitorsWithoutTypingAndTouchpadPauseKeepsDrafts() {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .options))
  #expect(app.showsControls == true)
  _ = app.receiveController(.init(connected: true, buttons: [.cross, .l2, .create], leftY: 1, rightTrigger: 1))
  _ = app.receiveController(.init(connected: true))
  #expect(app.predictive.tokenCount == 0 && app.predictive.draft.count == 0 && app.hasCopyRequest == false)
  _ = app.receiveController(.init(connected: true, buttons: .options))
  #expect(app.showsControls == false)
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .touchpad))
  #expect(app.inputPaused == true)
  _ = app.receiveController(.init(connected: true, leftY: 1))
  _ = app.receiveController(.init(connected: true, buttons: .r2, rightTrigger: 1))
  _ = app.receiveController(.init(connected: true))
  #expect(app.predictive.tokenCount == 0 && app.predictive.draft.count == 0)
  _ = app.receiveController(.init(connected: true, buttons: .touchpad, leftY: 1))
  _ = app.receiveController(.init(connected: true))
  #expect(app.inputPaused == false && app.predictive.tokenCount == 0)
  _ = app.receiveController(.init(connected: true, leftY: 1))
  _ = app.receiveController(.init(connected: true))
  #expect(app.predictive.tokenCount == 1)
}

@Test func keyboardTriggerNeutralGateAndDpadRightWheelAlternatives() {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  _ = app.receiveController(.init(connected: true, leftTrigger: 0.3))
  _ = app.receiveController(.init(connected: true, buttons: .r2, rightTrigger: 1))
  #expect(app.predictive.draft.count == 0)
  _ = app.receiveController(.init(connected: true))
  app.switchTo(.chords)
  app.chooseLeft(0)
  _ = app.receiveController(.init(connected: true, buttons: .up))
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .down))
  #expect(app.chords.draft.snapshot() == "ac")
  app.switchTo(.predictive)
  for group in [2, 1, 3, 3, 4] { app.predictive.addGroup(group) }
  app.predictive.deleteWord()
  #expect(app.predictive.tokenCount == 0 && app.predictive.draft.count == 0)
}

@Test func keyboardControlsRenderAtMaximumAndTinySizesAndExposePlatformLimits() throws {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  app.showsControls = true
  app.controlsDrawing.snapshot = .init(
    connected: true, buttons: .standard, leftX: -1, leftY: 1, rightX: 0.5, rightY: -0.5,
    leftTrigger: 1, rightTrigger: 0.5, supportedButtons: .standard.union(.touchpad),
    features: [.rightStick, .touchPositions],
    primaryTouch: .init(x: 0, y: 0), secondaryTouch: .init(x: 0.5, y: -0.5))
  var surface = try Surface(maximumSize: .init(columns: 240, rows: 80))
  for size in [
    TerminalSize(columns: 240, rows: 80), .init(columns: 80, rows: 24), .init(columns: 40, rows: 24),
    .init(columns: 1, rows: 1)
  ] {
    try surface.render(size: size) { app.render(in: size) }
  }
  let size = TerminalSize(columns: 80, rows: 24)
  try surface.render(size: size) { app.render(in: size) }
  var image = ""
  for y in 0..<size.rows {
    for x in 0..<size.columns { image.unicodeScalars.append(surface.cell(x: x, y: y)!.glyph.scalar) }
    image.append("\n")
  }
  #expect(
    image.contains("Create") && image.contains("Options") && image.contains("Touch click") && image.contains("Mic mute")
  )
  #expect(image.contains("contact state unavailable") && image.contains("not exposed"))
}
