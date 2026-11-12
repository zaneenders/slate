import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func documentEditingKeepsDiskUnchangedUntilWriteAndSupportsRepeatedSaves() throws {
  let fixture = try EditingFixture("hello\r\n")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  let budget = viewer.storageBudgetBytes
  var copy = CopyBuffer()
  #expect(viewer.event(.key(.character("i")), copyBuffer: &copy) == .redraw)
  #expect(viewer.isInserting && viewer.cursorByteOffset == 0)
  _ = viewer.event(.paste("prefix ".utf8Span), copyBuffer: &copy)
  #expect(viewer.isDirty && viewer.byteCount == 14 && viewer.cursorByteOffset == 7)
  #expect(try fixture.contents() == Data("hello\r\n".utf8))
  #expect(viewer.storageBudgetBytes == budget)
  _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  #expect(viewer.isWriting && !viewer.isInserting)
  #expect(try fixture.contents() == Data("hello\r\n".utf8))
  #expect(try finishEditingWrite(viewer) != .quit)
  #expect(!viewer.isDirty && !viewer.isWriting)
  #expect(try fixture.contents() == Data("prefix hello\r\n".utf8))
  try prepareViewer(viewer, in: size)
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("again ".utf8Span), copyBuffer: &copy)
  #expect(viewer.isDirty)
  #expect(try fixture.contents() == Data("prefix hello\r\n".utf8))
  _ = editingCommand("write", viewer: viewer, copyBuffer: &copy)
  _ = try finishEditingWrite(viewer)
  #expect(!viewer.isDirty)
  #expect(try fixture.contents() == Data("prefix again hello\r\n".utf8))
  #expect(viewer.storageBudgetBytes == budget)
  #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func documentEditingGuardsQuitShortcutsAndExplicitDiscardPreservesDisk() throws {
  let fixture = try EditingFixture("original")
  let viewer = try DocumentFileViewer(fixture.path)
  try prepareViewer(viewer, in: .init(columns: 80, rows: 24))
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("unsaved ".utf8Span), copyBuffer: &copy)
  for key in [InputKey.control(.q), .control(.c)] {
    #expect(viewer.event(.key(key), copyBuffer: &copy) == .redraw)
    #expect(viewer.isDirty && viewer.editNotice.contains("Unsaved"))
  }
  _ = viewer.event(.key(.escape), copyBuffer: &copy)
  #expect(!viewer.isInserting)
  #expect(viewer.event(.key(.character("q")), copyBuffer: &copy) == .redraw)
  #expect(editingCommand("q", viewer: viewer, copyBuffer: &copy) == .redraw)
  #expect(viewer.isDirty && !viewer.isWriting)
  #expect(editingCommand("q!", viewer: viewer, copyBuffer: &copy) == .quit)
  #expect(try fixture.contents() == Data("original".utf8))
  #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func documentEditingWriteQuitCommitsBeforeReportingQuit() throws {
  let fixture = try EditingFixture("body")
  let viewer = try DocumentFileViewer(fixture.path)
  try prepareViewer(viewer, in: .init(columns: 80, rows: 24))
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("new ".utf8Span), copyBuffer: &copy)
  #expect(editingCommand("wq", viewer: viewer, copyBuffer: &copy) == .redraw)
  #expect(viewer.isWriting)
  #expect(try fixture.contents() == Data("body".utf8))
  #expect(try finishEditingWrite(viewer) == .quit)
  #expect(try fixture.contents() == Data("new body".utf8))
  #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func documentEditingSaveAsKeepsOriginalAndMakesLaterWritesUseTheNewPath() throws {
  let fixture = try EditingFixture("body")
  let destination = fixture.directory.appendingPathComponent("renamed document.txt")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("new ".utf8Span), copyBuffer: &copy)
  _ = editingCommand("saveas " + destination.path, viewer: viewer, copyBuffer: &copy)
  #expect(viewer.isWriting && viewer.documentPath == fixture.path)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
  _ = try finishEditingWrite(viewer)
  #expect(viewer.documentPath == destination.path && !viewer.isDirty)
  #expect(try fixture.contents() == Data("body".utf8))
  #expect(try Data(contentsOf: destination) == Data("new body".utf8))
  try prepareViewer(viewer, in: size)
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("saved ".utf8Span), copyBuffer: &copy)
  _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  _ = try finishEditingWrite(viewer)
  #expect(try Data(contentsOf: destination) == Data("new saved body".utf8))
  #expect(try fixture.contents() == Data("body".utf8))
  #expect(!viewer.isDirty && viewer.documentPath == destination.path)
}

@Test func documentEditingRefusesExistingSaveAsDestinationAndRetainsUnsavedEdits() throws {
  let fixture = try EditingFixture("body")
  let destination = fixture.directory.appendingPathComponent("occupied")
  try Data("other document".utf8).write(to: destination, options: .withoutOverwriting)
  let viewer = try DocumentFileViewer(fixture.path)
  try prepareViewer(viewer, in: .init(columns: 80, rows: 24))
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("new ".utf8Span), copyBuffer: &copy)
  _ = editingCommand("saveas " + destination.path, viewer: viewer, copyBuffer: &copy)
  #expect(!viewer.isWriting && viewer.isDirty && viewer.documentPath == fixture.path)
  #expect(viewer.editNotice.contains("already exists"))
  #expect(try fixture.contents() == Data("body".utf8))
  #expect(try Data(contentsOf: destination) == Data("other document".utf8))
  // Failed publication leaves the edited buffer available for an ordinary write.
  _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  _ = try finishEditingWrite(viewer)
  #expect(try fixture.contents() == Data("new body".utf8))
  #expect(!viewer.isDirty)
  #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func documentEditingCanCancelAStreamingWriteWithoutChangingDiskOrLosingEdits() throws {
  let original = String(repeating: "0123456789abcdef", count: 16_384)
  let fixture = try EditingFixture(original)
  let viewer = try DocumentFileViewer(fixture.path)
  try prepareViewer(viewer, in: .init(columns: 80, rows: 24))
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("edit ".utf8Span), copyBuffer: &copy)
  _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  _ = viewer.performPendingWork()
  _ = viewer.performPendingWork()
  #expect(viewer.isWriting && viewer.writtenBytes > 0 && viewer.writtenBytes < viewer.byteCount)
  #expect(try fixture.contents() == Data(original.utf8))
  #expect(viewer.event(.key(.escape), copyBuffer: &copy) == .redraw)
  #expect(!viewer.isWriting && viewer.isDirty && viewer.editNotice.contains("cancelled"))
  #expect(try fixture.contents() == Data(original.utf8))
  #expect(try fixture.temporaryFiles().isEmpty)
  _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  _ = try finishEditingWrite(viewer)
  #expect(try fixture.contents() == Data(("edit " + original).utf8))
  #expect(!viewer.isDirty)
}

@Test(arguments: [false, true])
func documentEditingRejectsExternalChangesBeforeOrDuringWrite(changeDuringWrite: Bool) throws {
  let original = String(repeating: "a", count: 131_072)
  let fixture = try EditingFixture(original)
  let viewer = try DocumentFileViewer(fixture.path)
  try prepareViewer(viewer, in: .init(columns: 80, rows: 24))
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("local ".utf8Span), copyBuffer: &copy)
  if changeDuringWrite {
    _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
    _ = viewer.performPendingWork()
    try #require(viewer.isWriting)
  }
  // Same-inode mutation exercises the source reader check as well as writer
  // conflict handling, without allowing an atomic fixture write to hide it.
  let handle = try FileHandle(forWritingTo: fixture.url)
  try handle.truncate(atOffset: 0)
  try handle.write(contentsOf: Data("external".utf8))
  try handle.close()
  if changeDuringWrite {
    _ = viewer.performPendingWork()
  } else {
    _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  }
  #expect(!viewer.isWriting && viewer.isDirty)
  #expect(viewer.byteCount == original.utf8.count + 6)
  #expect(viewer.editNotice.lowercased().contains("changed"))
  #expect(try fixture.contents() == Data("external".utf8))
  #expect(try fixture.temporaryFiles().isEmpty)
  // A failed viewport refresh must still let the user discard and quit.
  try prepareViewer(viewer, in: .init(columns: 80, rows: 24))
  #expect(editingCommand("q!", viewer: viewer, copyBuffer: &copy) == .quit)
}

@Test func documentEditingReplacesSelectedUnicodeBytesAndPreservesSurroundingContent() throws {
  let fixture = try EditingFixture("Aé漢Z")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  let layout = DocumentViewerLayout(size: size, byteCount: viewer.byteCount, showInspector: true)
  var copy = CopyBuffer()
  _ = viewer.event(
    .mouse(.init(action: .press, button: .left, column: layout.text.x + 1, row: layout.text.y)), copyBuffer: &copy)
  _ = viewer.event(
    .mouse(.init(action: .move, button: .left, column: layout.text.x + 3, row: layout.text.y)), copyBuffer: &copy)
  _ = viewer.event(
    .mouse(.init(action: .release, button: .left, column: layout.text.x + 3, row: layout.text.y)), copyBuffer: &copy)
  #expect(viewer.selectionRange == 1..<6)
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("X".utf8Span), copyBuffer: &copy)
  #expect(viewer.byteCount == 3 && viewer.cursorByteOffset == 2)
  #expect(viewer.selectionRange == nil && viewer.isDirty)
  #expect(try fixture.contents() == Data("Aé漢Z".utf8))
  _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  _ = try finishEditingWrite(viewer)
  #expect(try fixture.contents() == Data("AXZ".utf8))
}

@Test func documentEditingStreamsAMultiMegabyteFileAfterEditingNearItsEnd() throws {
  let original = String(repeating: "0123456789abcdef", count: 131_072)
  let fixture = try EditingFixture(original)
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  _ = viewer.handle(.character("9"), modifiers: [])
  try prepareViewer(viewer, in: size)
  let insertionOffset = viewer.visibleRange.lowerBound
  try #require(insertionOffset > 1_048_576)
  let budget = viewer.storageBudgetBytes
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  _ = viewer.event(.paste("EDIT".utf8Span), copyBuffer: &copy)
  #expect(viewer.isDirty && viewer.byteCount == original.utf8.count + 4)
  #expect(viewer.storageBudgetBytes == budget)
  _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  _ = try finishEditingWrite(viewer)
  var expected = Data(original.utf8)
  expected.replaceSubrange(insertionOffset..<insertionOffset, with: "EDIT".utf8)
  #expect(try fixture.contents() == expected)
  #expect(!viewer.isDirty && viewer.storageBudgetBytes == budget)
}

@Test func documentEditingMouseClickRedrawsTheCursorAndInsertsAtTheClickedByte() throws {
  let fixture = try EditingFixture("abcdef")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  try prepareViewer(viewer, in: size)
  let layout = DocumentViewerLayout(size: size, byteCount: viewer.byteCount, showInspector: true)
  var copy = CopyBuffer()
  _ = viewer.event(.key(.character("i")), copyBuffer: &copy)
  let press = MouseEvent(action: .press, button: .left, column: layout.text.x + 3, row: layout.text.y)
  #expect(viewer.event(.mouse(press), copyBuffer: &copy) == .redraw)
  _ = viewer.event(
    .mouse(.init(action: .release, button: .left, column: press.column, row: press.row)), copyBuffer: &copy)
  #expect(viewer.cursorByteOffset == 3 && viewer.selectionRange == nil)
  _ = viewer.event(.paste("X".utf8Span), copyBuffer: &copy)
  _ = editingCommand("w", viewer: viewer, copyBuffer: &copy)
  _ = try finishEditingWrite(viewer)
  #expect(try fixture.contents() == Data("abcXdef".utf8))
}

@discardableResult
private func editingCommand(_ command: String, viewer: DocumentFileViewer, copyBuffer: inout CopyBuffer) -> ScreenUpdate
{
  if viewer.isInserting { _ = viewer.event(.key(.escape), copyBuffer: &copyBuffer) }
  _ = viewer.event(.key(.character(":")), copyBuffer: &copyBuffer)
  #expect(viewer.commandVisible)
  _ = viewer.event(.paste(command.utf8Span), copyBuffer: &copyBuffer)
  return viewer.event(.key(.enter), copyBuffer: &copyBuffer)
}

@discardableResult
private func finishEditingWrite(_ viewer: DocumentFileViewer) throws -> ScreenUpdate {
  var update = ScreenUpdate.none
  for _ in 0..<65_536 {
    guard viewer.isWriting else { return update }
    update = viewer.performPendingWork()
    if update == .quit { return update }
  }
  try #require(!viewer.isWriting, "Write/reindex exceeded the bounded fixture workload")
  return update
}

private struct EditingFixture: ~Copyable {
  let directory: URL
  let url: URL
  var path: String { url.path }

  init(_ content: String) throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "slate-edit-tests-" + UUID().uuidString)
    url = directory.appendingPathComponent("document.txt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data(content.utf8).write(to: url, options: .withoutOverwriting)
  }

  borrowing func contents() throws -> Data { try Data(contentsOf: url) }
  borrowing func temporaryFiles() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".slate-write-") }
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
}
