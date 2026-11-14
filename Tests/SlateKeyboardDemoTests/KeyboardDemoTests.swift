import Slate
import SlateGamepad
import SlateTestSupport
import Testing

@testable import SlateKeyboardDemo

@Test func keyboardVocabularyPredictionCollisionsAndContext() {
  let lexicon = KeyboardLexicon()
  #expect(lexicon.count > 200 && lexicon.count <= 512)
  let session = KeyboardSession(mode: .predictive, lexicon: lexicon)
  for sector in [2, 4, 4, 1] { session.addGroup(sector) }  // 4663
  #expect(session.preview == "good")
  #expect((0..<session.candidateCount).map { session.candidate($0) }.contains("home"))
  session.cancel()
  for byte in "go ".utf8 { session.type(byte) }
  for sector in [2, 4, 4, 1] { session.addGroup(sector) }
  #expect(session.preview == "home")
  session.finish()
  #expect(session.draft.snapshot() == "go home ")
  #expect(session.tokenCount == 0 && session.candidateCount == 0)
  for sector in [2, 1, 3, 3, 4] { session.addGroup(sector) }
  #expect(session.preview == "hello")
  session.capitals = true
  session.finish(period: true)
  #expect(session.draft.snapshot() == "go home HELLO. ")
}

@Test func keyboardCapacityRejectionsAreAtomicAndDeletionRecovers() {
  let session = KeyboardSession(mode: .predictive, lexicon: KeyboardLexicon())
  for _ in 0..<16 { session.addGroup(7) }
  #expect(session.tokenCount == 16 && session.candidateCount == 0)
  session.addGroup(0)
  #expect(session.tokenCount == 16 && session.notice == .wordFull)
  session.finish()
  #expect(session.draft.count == 0 && session.tokenCount == 16 && session.notice == .unknownWord)
  session.delete()
  #expect(session.tokenCount == 15)
  session.cancel()
  for _ in 0..<510 { session.type(97) }
  for sector in [2, 1, 3, 3, 4] { session.addGroup(sector) }
  session.finish()
  #expect(session.draft.count == 510 && session.tokenCount == 5 && session.notice == .draftFull)
  session.cancel()
  session.type(98)
  session.type(99)
  session.type(100)
  #expect(session.draft.count == 512 && session.draft[511] == 99 && session.notice == .draftFull)
  session.finish(period: true)
  #expect(session.draft.count == 512 && session.draft[511] == 99)
  session.delete()
  session.delete()
  session.finish(period: true)
  #expect(session.draft.count == 512 && session.draft[510] == 46 && session.draft[511] == 32)
}

@Test func keyboardEveryLiteralLayoutCoversTheAlphabetAndRejectsEmptySlots() {
  var common = Set<UInt8>()
  var chords = Set<UInt8>()
  for group in 0..<8 {
    common.insert(KeyboardLetters.common[group])
    for sector in [0, 2, 4, 6] {
      if let byte = KeyboardLetters.letter(group: group, sector: sector, extras: true), (97...122).contains(byte) {
        common.insert(byte)
      }
      if let byte = KeyboardLetters.letter(group: group, sector: sector, extras: false) { chords.insert(byte) }
    }
  }
  #expect(common == Set(UInt8(97)...UInt8(122)))
  #expect(chords == common)
  #expect(KeyboardLetters.letter(group: 0, sector: 6, extras: false) == nil)
  #expect(KeyboardLetters.letter(group: 0, sector: 1, extras: false) == nil)
}

@Test func keyboardStickFlickNeutralGateHoldNoiseAndAllEightDirections() {
  var stick = StickFlick(eightWay: true)
  #expect(stick.update(x: 1, y: 0) == nil && stick.active == nil)
  #expect(stick.update(x: 0, y: 0) == nil)
  #expect(stick.update(x: 0.54, y: 0) == nil && stick.active == nil)
  let vectors: [(Float, Float)] = [(0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)]
  for (sector, vector) in vectors.enumerated() {
    for _ in 0..<20 { #expect(stick.update(x: vector.0, y: vector.1) == nil) }
    #expect(stick.active == sector)
    #expect(stick.update(x: 0, y: 0) == sector)
    #expect(stick.update(x: 0, y: 0) == nil)
  }
  _ = stick.update(x: 1, y: 0)
  #expect(stick.update(x: .nan, y: 0) == nil && stick.active == nil)
  #expect(stick.update(x: 0, y: 0) == nil)
  _ = stick.update(x: 0.55, y: 0)
  #expect(stick.update(x: 0.36, y: 0) == nil && stick.active == 2)
  #expect(stick.update(x: 0.35, y: 0) == 2)
  // A radial dead zone has the same travel distance on diagonals and cardinals.
  _ = stick.update(x: 0.39, y: 0.39)
  #expect(stick.active == 1)
  #expect(stick.update(x: 0.24, y: 0.24) == 1)
}

@Test func keyboardControllerTypingDoesNotRepeatAndTabsPreserveDrafts() {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, leftY: 1))
  for _ in 0..<100 { _ = app.receiveController(.init(connected: true, leftY: 1)) }
  #expect(app.predictive.tokenCount == 0)
  _ = app.receiveController(.init(connected: true))
  #expect(app.predictive.tokenCount == 1)
  _ = app.receiveController(.init(connected: true, buttons: .right))
  #expect(app.mode == .common && app.predictive.tokenCount == 1)
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, leftY: 1))
  _ = app.receiveController(.init(connected: true))
  #expect(app.common.draft.snapshot() == "e")
  _ = app.receiveController(.init(connected: true, buttons: .south))
  for _ in 0..<20 { _ = app.receiveController(.init(connected: true, buttons: .south)) }
  #expect(app.common.draft.snapshot() == "e ")
  app.switchTo(.predictive)
  #expect(app.session.tokenCount == 1)
}

@Test func keyboardControllerChordLatchesItsGroupAndRequiresNeutralAfterCancelOrDisconnect() {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  app.switchTo(.chords)
  _ = app.receiveController(.init(connected: true))
  // Hold left on ABC, engage right on its first letter.
  _ = app.receiveController(.init(connected: true, leftY: 1))
  _ = app.receiveController(.init(connected: true, leftY: 1, rightY: 1))
  #expect(app.chords.latchedGroup == 0)
  // Moving left to DEF must not change the chord already in flight.
  _ = app.receiveController(.init(connected: true, leftX: 1, leftY: 1, rightY: 1))
  _ = app.receiveController(.init(connected: true, leftX: 1, leftY: 1))
  #expect(app.chords.draft.snapshot() == "a")
  _ = app.receiveController(.init(connected: true, buttons: .east, rightX: 1))
  _ = app.receiveController(.init(connected: true))
  #expect(app.chords.draft.snapshot() == "a")
  _ = app.receiveController(.init(connected: true, rightX: 1))
  _ = app.receiveController(.init())
  _ = app.receiveController(.init(connected: true, rightX: 1))
  _ = app.receiveController(.init(connected: true))
  #expect(app.chords.draft.snapshot() == "a")
}

@Test func keyboardCommonMoreLayerCannotLeakALetterOnShoulderRelease() {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  app.switchTo(.common)
  _ = app.receiveController(.init(connected: true))
  _ = app.receiveController(.init(connected: true, buttons: .rightShoulder))
  _ = app.receiveController(.init(connected: true, buttons: .rightShoulder))
  _ = app.receiveController(.init(connected: true, buttons: .rightShoulder, leftY: 1))
  _ = app.receiveController(.init(connected: true, buttons: .rightShoulder, leftY: 1, rightX: 1))
  _ = app.receiveController(.init(connected: true, buttons: .rightShoulder, leftY: 1))
  #expect(app.common.draft.snapshot() == "c")
  _ = app.receiveController(.init(connected: true, leftY: 1))
  _ = app.receiveController(.init(connected: true))
  #expect(app.common.draft.snapshot() == "c" && app.common.moreLetters == false)
}

@Test func keyboardDemoRendersAndMouseAndKeyboardUseTheSameControls() throws {
  var app = SlateKeyboardDemo()
  app.controllerEnabled = false
  var surface = try Surface(maximumSize: .init(columns: 120, rows: 40))
  var copy = CopyBuffer()
  let size = TerminalSize(columns: 80, rows: 24)
  try surface.render(size: size) { app.render(in: size) }
  let tab = try #require(app.hits.bounds(for: .tab(.chords)))
  _ = app.event(.mouse(.init(action: .press, button: .left, column: tab.x, row: tab.y)), copyBuffer: &copy)
  #expect(app.mode == .chords)
  try surface.render(size: size) { app.render(in: size) }
  let left = try #require(app.hits.bounds(for: .leftWheel))
  let key = KeyboardWheelGeometry.button(0, width: left.width, height: left.height)
  _ = app.event(
    .mouse(.init(action: .press, button: .left, column: left.x + key.x + 4, row: left.y + key.y)), copyBuffer: &copy)
  _ = app.event(.key(.right), copyBuffer: &copy)
  #expect(app.chords.draft.snapshot() == "b")
  _ = app.event(.key(.enter), copyBuffer: &copy)
  #expect(app.chords.draft.snapshot() == "b ")
  #expect(app.event(.key(.control(.q)), copyBuffer: &copy) == .quit)
  for mode in KeyboardMode.allCases {
    app.switchTo(mode)
    for viewport in [
      TerminalSize(columns: 120, rows: 40), .init(columns: 80, rows: 24), .init(columns: 40, rows: 24),
      .init(columns: 1, rows: 1)
    ] {
      try surface.render(size: viewport) { app.render(in: viewport) }
    }
  }
}
