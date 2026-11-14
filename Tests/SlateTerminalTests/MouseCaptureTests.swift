import SlateTerminal
import SlateUI
import Testing

@Test func mouseCaptureRoutesOutsideBoundsAndAppliesFinalReleasePosition() throws {
  let hits = HitMap<Int>()
  let size = TerminalSize(columns: 12, rows: 6)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { Text("target").hitRegion(1, in: hits).position(column: 3, row: 2) }
  var capture = MouseCapture<Int>()
  let press = MouseEvent(action: .press, button: .left, column: 5, row: 2)
  let hit = try #require(hits.hitTest(press))
  capture.begin(hit, in: hits)
  #expect(capture.target == 1)
  let outside = capture.route(.init(action: .move, button: .left, column: 0, row: 0))
  #expect(outside?.id == 1 && outside?.column == -3 && outside?.row == -2)
  #expect(capture.route(.init(action: .scrollDown, column: 0, row: 0)) == nil)
  #expect(capture.target == 1)
  let release = capture.route(.init(action: .release, column: 11, row: 5))
  #expect(release?.column == 8 && release?.row == 3)
  #expect(capture.target == nil)
  #expect(capture.route(.init(action: .move, button: .left, column: 5, row: 2)) == nil)
}

@Test func mouseCaptureSurvivesMovementReorderingAndRejectedLayouts() throws {
  let hits = HitMap<Int>()
  let size = TerminalSize(columns: 12, rows: 6)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) {
    Overlay {
      Text("first").hitRegion(1, in: hits)
      Text("second").hitRegion(2, in: hits).position(column: 4, row: 2)
    }
  }
  var capture = MouseCapture<Int>()
  capture.begin(try #require(hits.hitTest(column: 5, row: 2)), in: hits)
  try surface.render(size: size) {
    Overlay {
      Text("second").hitRegion(2, in: hits).position(column: 5, row: 3)
      Text("first").hitRegion(1, in: hits)
    }
  }
  #expect(capture.target == 2)
  let moved = capture.route(.init(action: .move, button: .left, column: 6, row: 3))
  #expect(moved?.column == 1 && moved?.row == 0)
  #expect(throws: SurfaceError.layout(.textTooLong)) {
    try surface.render(size: size) { Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1)) }
  }
  #expect(capture.target == 2)
}

@Test func mouseCaptureCancelsOnRemovalReappearanceResizeAndMissingRelease() throws {
  let hits = HitMap<Int>()
  let size = TerminalSize(columns: 12, rows: 6)
  var surface = try Surface(maximumSize: size)
  var capture = MouseCapture<Int>()
  try surface.render(size: size) { Text("target").hitRegion(1, in: hits) }
  let original = try #require(hits.hitTest(column: 0, row: 0))
  capture.begin(original, in: hits)
  try surface.render(size: size) { Text("hidden") }
  try surface.render(size: size) { Text("target").hitRegion(1, in: hits) }
  #expect(capture.target == nil)
  #expect(capture.route(.init(action: .move, button: .left, column: 1, row: 0)) == nil)
  capture.begin(try #require(hits.hitTest(column: 0, row: 0)), in: hits)
  let smaller = TerminalSize(columns: 10, rows: 5)
  try surface.render(size: smaller) { Text("target").hitRegion(1, in: hits) }
  #expect(capture.target == nil)
  capture.begin(try #require(hits.hitTest(column: 0, row: 0)), in: hits)
  #expect(capture.route(.init(action: .move, column: 1, row: 0)) == nil)
  #expect(capture.target == nil)
  capture.begin(try #require(hits.hitTest(column: 0, row: 0)), in: hits)
  #expect(capture.route(.init(action: .press, button: .right, column: 1, row: 0)) == nil)
  #expect(capture.target == nil)
  capture.begin(try #require(hits.hitTest(column: 0, row: 0)), in: hits, button: .right)
  #expect(capture.route(.init(action: .release, button: .right, column: 8, row: 4))?.id == 1)
  #expect(capture.target == nil)
}

@Test func mouseCaptureRejectsHitsFromAnotherMap() throws {
  let first = HitMap<Int>()
  let second = HitMap<Int>()
  let size = TerminalSize(columns: 4, rows: 1)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) {
    Text("one").hitRegion(1, in: first).hitRegion(1, in: second)
  }
  var capture = MouseCapture<Int>()
  capture.begin(try #require(first.hitTest(column: 0, row: 0)), in: second)
  #expect(capture.target == nil)
}
