import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func documentInsertDownAtEOFKeepsTheCursorAtEOF() throws {
  let fixture = try CursorFixture("abc")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.key(.end), copyBuffer: &copy)
  try prepareViewer(viewer, in: size)
  #expect(viewer.cursorByteOffset == 3)
  _ = viewer.event(.key(.down), copyBuffer: &copy)
  #expect(viewer.cursorByteOffset == 3)
  _ = viewer.event(.key(.pageDown), copyBuffer: &copy)
  #expect(viewer.cursorByteOffset == 3 && !viewer.isDirty)
}

@Test func documentInsertIgnoresMouseOffsetsFromAnObsoleteViewport() throws {
  let fixture = try CursorFixture("abcdefghij")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  let layout = DocumentViewerLayout(size: size, byteCount: viewer.byteCount, showInspector: true)
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("prefix ".utf8Span), copyBuffer: &copy)
  #expect(viewer.cursorByteOffset == 7)
  // These cells still describe the original file. No frame has published the
  // new overlay yet, so they cannot become edits against its shifted offsets.
  _ = viewer.event(
    .mouse(.init(action: .press, button: .left, column: layout.text.x + 2, row: layout.text.y)), copyBuffer: &copy)
  _ = viewer.event(
    .mouse(.init(action: .move, button: .left, column: layout.text.x + 4, row: layout.text.y)), copyBuffer: &copy)
  _ = viewer.event(
    .mouse(.init(action: .release, button: .left, column: layout.text.x + 4, row: layout.text.y)), copyBuffer: &copy)
  #expect(viewer.cursorByteOffset == 7 && viewer.selectionRange == nil)
  _ = viewer.event(.paste("X".utf8Span), copyBuffer: &copy)
  #expect(viewer.cursorByteOffset == 8 && viewer.byteCount == 18)
}

@Test func documentInsertDownPastTheViewportPreservesItsColumn() throws {
  let fixture = try CursorFixture(String(repeating: "0123456789", count: 2_048))
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  let layout = DocumentViewerLayout(size: size, byteCount: viewer.byteCount, showInspector: true)
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  for _ in 0..<3 { _ = viewer.event(.key(.right), copyBuffer: &copy) }
  for _ in 0..<layout.text.height - 1 { _ = viewer.event(.key(.down), copyBuffer: &copy) }
  let bottom = (layout.text.height - 1) * layout.text.width + 3
  #expect(viewer.cursorByteOffset == bottom)
  _ = viewer.event(.key(.down), copyBuffer: &copy)
  try prepareViewer(viewer, in: size)
  #expect(viewer.cursorByteOffset == bottom + layout.text.width)
  #expect(viewer.firstByte > 0 && !viewer.isDirty)
}

@Test func documentInsertAfterAJumpUsesTheRequestedPositionBeforeAnyRedraw() throws {
  let fixture = try CursorFixture("abcdefghijk")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("9")), copyBuffer: &copy)
  #expect(viewer.firstByte == 9)
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  #expect(viewer.isInserting && viewer.cursorByteOffset == 9)
  _ = viewer.event(.paste("X".utf8Span), copyBuffer: &copy)
  #expect(viewer.cursorByteOffset == 10 && viewer.byteCount == 12)
}

private struct CursorFixture: ~Copyable {
  let path: String

  init(_ text: String) throws {
    path = NSTemporaryDirectory() + "slate-cursor-" + UUID().uuidString
    try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }

  deinit { try? FileManager.default.removeItem(atPath: path) }
}
