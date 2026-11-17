import Slate
import SlateGamepad
import Testing

@testable import SlateKeyboardDemo

@Test @MainActor func keyboardLettersCoverTheAlphabetAndRejectMissingPositions() {
  var letters: [UInt8] = []
  for group in 0..<8 {
    for sector in stride(from: 0, to: 8, by: 2) {
      if let byte = KeyboardLetters.letter(group: group, sector: sector) { letters.append(byte) }
    }
  }
  #expect(String(decoding: letters, as: UTF8.self) == "abcdefghijklmnopqrstuvwxyz")
  #expect(KeyboardLetters.letter(group: 0, sector: 6) == nil)
  #expect(KeyboardLetters.letter(group: 0, sector: 1) == nil)
}

@Test @MainActor func keyboardStickFlickRequiresNeutralAndCommitsOnceInAllEightDirections() {
  var stick = StickFlick(eightWay: true)
  #expect(stick.update(x: 1, y: 0) == nil && stick.active == nil)
  _ = stick.update(x: 0, y: 0)
  let vectors: [(Float, Float)] = [(0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)]
  for (sector, vector) in vectors.enumerated() {
    for _ in 0..<20 { #expect(stick.update(x: vector.0, y: vector.1) == nil) }
    #expect(stick.active == sector)
    #expect(stick.update(x: 0, y: 0) == sector)
    #expect(stick.update(x: 0, y: 0) == nil)
  }
  _ = stick.update(x: 0.55, y: 0)
  #expect(stick.update(x: 0.36, y: 0) == nil && stick.active == 2)
  #expect(stick.update(x: 0.35, y: 0) == 2)
  _ = stick.update(x: 0.39, y: 0.39)
  #expect(stick.active == 1)
  #expect(stick.update(x: 0.24, y: 0.24) == 1)
  _ = stick.update(x: .nan, y: 0)
  #expect(stick.active == nil)
}

@Test @MainActor func keyboardControllerLatchesGroupsAndRequiresNeutralAfterReconnectAndCancel() {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  var copy = CopyBuffer()
  _ = app.receiveController(.init(connected: true, leftY: 1, rightY: 1), copyBuffer: &copy)
  #expect(app.selectedGroup == nil)
  _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
  _ = app.receiveController(.init(connected: true, leftY: 1, rightY: 1), copyBuffer: &copy)
  for _ in 0..<20 { _ = app.receiveController(.init(connected: true, leftY: 1, rightY: 1), copyBuffer: &copy) }
  #expect(app.draft.byteCount == 0)
  _ = app.receiveController(.init(connected: true, leftX: 1, leftY: 1, rightY: 1), copyBuffer: &copy)
  _ = app.receiveController(.init(connected: true, leftX: 1, leftY: 1), copyBuffer: &copy)
  #expect(app.draft.snapshot() == "a")
  _ = app.receiveController(.init(connected: true, buttons: .east, rightY: 1), copyBuffer: &copy)
  _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
  #expect(app.draft.snapshot() == "a" && app.selectedGroup == nil)
  _ = app.receiveController(.init(), copyBuffer: &copy)
  _ = app.receiveController(.init(connected: true, leftY: 1, rightY: 1), copyBuffer: &copy)
  _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
  #expect(app.draft.snapshot() == "a")
}

@Test @MainActor func keyboardControllerCommandsAreEdgedAndCopyTheDraft() {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  var copy = CopyBuffer()
  _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
  for buttons: GamepadButtons in [.leftShoulder, [], .south, .south, [], .create] {
    _ = app.receiveController(.init(connected: true, buttons: buttons), copyBuffer: &copy)
  }
  #expect(app.capitals && app.draft.snapshot() == " ")
  var copied = ""
  copy.flush { copied = String(copying: $0) }
  #expect(copied == " ")
  _ = app.receiveController(.init(connected: true, buttons: .west), copyBuffer: &copy)
  #expect(app.draft.byteCount == 0)
}

@Test @MainActor func keyboardMouseAndKeysUseTheRenderedGroupGeometry() throws {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  var surface = try Surface(maximumSize: .init(columns: 240, rows: 80))
  var copy = CopyBuffer()
  for size in [TerminalSize(columns: 240, rows: 80), .init(columns: 80, rows: 24), .init(columns: 1, rows: 1)] {
    try surface.render(size: size) { app.render(in: size) }
  }
  try surface.render(size: .init(columns: 80, rows: 24)) { app.render(in: .init(columns: 80, rows: 24)) }
  let bounds = try #require(app.hits.bounds(for: .group(5)))
  _ = app.event(.mouse(.init(action: .press, button: .left, column: bounds.x, row: bounds.y)), copyBuffer: &copy)
  _ = app.event(.key(.left, modifiers: []), copyBuffer: &copy)
  #expect(app.draft.snapshot() == "s")
  _ = app.event(.key(.character("1"), modifiers: []), copyBuffer: &copy)
  #expect(app.receiveController(.init(), copyBuffer: &copy) == .none)
  _ = app.event(.key(.up, modifiers: []), copyBuffer: &copy)
  #expect(app.draft.snapshot() == "sa")
  #expect(app.event(.key(.character("q"), modifiers: .control), copyBuffer: &copy) == .quit)
}
