import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func textSelectionStaysInsideTheBytePaneWhenDraggedIntoTheInspector() throws {
  let fixture = try SelectionFixture(String(repeating: "0123456789abcdef", count: 1_024))
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 120, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  let inspector = try #require(layout.inspector)
  try prepareViewer(viewer, in: size)
  let stats = viewer.statistics
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x + 2, row: layout.text.y + 1))
  #expect(viewer.selectionRange == nil)
  _ = viewer.mouse(.init(action: .move, button: .left, column: inspector.x + 3, row: layout.text.y + 4))
  _ = viewer.mouse(.init(action: .release, button: .left, column: inspector.x + 3, row: layout.text.y + 4))
  let selected = try #require(viewer.selectionRange)
  #expect(selected == (layout.text.width + 2)..<(layout.text.width * 5))
  #expect(viewer.statistics == stats && viewer.firstByte == 0)
  try prepareViewer(viewer, in: size)
  #expect(viewer.statistics == stats && viewer.selectionRange == selected)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { frame in
    viewer.paint(in: &frame)
    var highlighted = 0
    for row in 0..<size.rows {
      for column in 0..<size.columns where frame[column, row].style.background == .indexed(60) {
        #expect((layout.text.x..<layout.text.right).contains(column))
        #expect((layout.text.y..<layout.text.bottom).contains(row))
        let offset = (row - layout.text.y) * layout.text.width + column - layout.text.x
        #expect(selected.contains(offset))
        highlighted += 1
      }
    }
    #expect(highlighted == selected.count)
  }
  var copy = CopyBuffer()
  #expect(viewer.copySelection(to: &copy) == .redraw)
  copy.flush { text in
    #expect(String(copying: text) == String(decoding: fixture.bytes[selected], as: UTF8.self))
    #expect(!String(copying: text).contains("\n"))  // Soft wraps add no bytes.
  }
  #expect(viewer.statistics == stats)
}

@Test func textSelectionSupportsReverseDragAndIgnoresMotionAfterRelease() throws {
  let fixture = try SelectionFixture(String(repeating: "abcdef", count: 1_024))
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  try prepareViewer(viewer, in: size)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x + 5, row: layout.text.y + 3))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 0, row: 0))
  _ = viewer.mouse(.init(action: .release, button: .left, column: 0, row: 0))
  let selected = try #require(viewer.selectionRange)
  #expect(selected == 0..<(layout.text.width * 3 + 6))
  #expect(viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534)) == .none)
  #expect(viewer.selectionRange == selected)
  #expect(viewer.handle(.escape, modifiers: []) == .redraw && viewer.selectionRange == nil)
  #expect(viewer.handle(.escape, modifiers: []) == .quit)
}

@Test func textSelectionWorksWithoutAScrollbarAndSkipsBlankCells() throws {
  let fixture = try SelectionFixture("abcdef")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 31, rows: 10)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  #expect(layout.scrollbarColumn == nil)
  try prepareViewer(viewer, in: size)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x + 1, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534))
  _ = viewer.mouse(.init(action: .release, button: .left, column: 65_534, row: 65_534))
  #expect(viewer.selectionRange == 1..<6)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x + 10, row: layout.text.y))
  #expect(viewer.selectionRange == nil)
  _ = viewer.mouse(.init(action: .move, button: .left, column: layout.text.x, row: layout.text.y))
  #expect(viewer.selectionRange == nil)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
  _ = viewer.mouse(.init(action: .release, button: .left, column: layout.text.x, row: layout.text.y))
  #expect(viewer.selectionRange == nil)  // A click is not a text selection.
  let empty = try SelectionFixture("")
  let emptyViewer = try DocumentFileViewer(empty.path)
  try prepareViewer(emptyViewer, in: size)
  _ = emptyViewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
  _ = emptyViewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534))
  #expect(emptyViewer.selectionRange == nil)
}

@Test func textSelectionClearsOnScrollResizeAndClicksOutsideTheRegion() throws {
  let fixture = try SelectionFixture(String(repeating: "0123456789", count: 2_048))
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 120, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  try prepareViewer(viewer, in: size)
  selectFirstRow(viewer, in: layout)
  _ = viewer.handle(.down, modifiers: [])
  try prepareViewer(viewer, in: size)
  #expect(viewer.selectionRange == nil)
  selectFirstRow(viewer, in: layout)
  try prepareViewer(viewer, in: .init(columns: 80, rows: 24))
  #expect(viewer.selectionRange == nil)
  try prepareViewer(viewer, in: size)
  selectFirstRow(viewer, in: layout)
  let inspector = try #require(layout.inspector)
  #expect(viewer.mouse(.init(action: .press, button: .left, column: inspector.x + 2, row: layout.text.y)) == .redraw)
  #expect(viewer.selectionRange == nil)
  selectFirstRow(viewer, in: layout)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.scrollbarColumn!, row: layout.text.bottom - 1))
  #expect(viewer.selectionRange == nil)
  try prepareViewer(viewer, in: size)
  _ = viewer.mouse(.init(action: .release, button: .left, column: layout.scrollbarColumn!, row: layout.text.bottom - 1))
  selectFirstRow(viewer, in: layout)
  let file = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
  try file.truncate(atOffset: 1)
  try file.close()
  try prepareViewer(viewer, in: size)
  #expect(viewer.selectionRange == nil && viewer.notice.contains("File changed"))
}

@Test func selectionCopiesDisplayedASCIIAndKeepsThePreparedViewportIntact() throws {
  let fixture = try SelectionFixture("Aé\t\u{1b}Z\n")
  var source = try PagedFileDocument.open(fixture.path)
  var viewport = try FileByteViewport(maximumSize: .init(columns: 8, rows: 2))
  try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  var copy = CopyBuffer()
  viewport.copy(1..<fixture.bytes.count, to: &copy)
  copy.flush { text in #expect(String(copying: text) == "é..Z.") }
  #expect(viewport.byte(at: 0) == 0x41 && viewport.byte(at: 1) == 0xc3)
  try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  #expect(viewport.byte(at: 1) == 0xc3)
}

@Test func documentDemoCopiesSelectionWithYOrControlCInsteadOfQuitting() throws {
  let fixture = try SelectionFixture(String(repeating: "0123456789abcdef", count: 1_024))
  var application = SlateDocumentDemo(path: fixture.path)
  _ = application.performPendingWork()
  let size = TerminalSize(columns: 120, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  _ = application.render(in: size)
  try finishApplicationWork(&application, size: size)
  var copy = CopyBuffer()
  _ = application.event(
    .mouse(.init(action: .press, button: .left, column: layout.text.x + 2, row: layout.text.y)), copyBuffer: &copy)
  _ = application.event(
    .mouse(.init(action: .move, button: .left, column: layout.text.x + 6, row: layout.text.y)), copyBuffer: &copy)
  _ = application.event(
    .mouse(.init(action: .release, button: .left, column: layout.text.x + 6, row: layout.text.y)), copyBuffer: &copy)
  for (key, modifiers) in [(InputKey.character("y"), KeyModifiers()), (.control(.c), []), (.character("c"), .control)] {
    #expect(application.event(.key(key, modifiers: modifiers), copyBuffer: &copy) == .redraw)
    var delivered = false
    copy.flush { text in
      delivered = true
      #expect(String(copying: text) == "23456")
    }
    #expect(delivered)
  }
  #expect(application.event(.key(.escape, modifiers: []), copyBuffer: &copy) == .redraw)
  #expect(application.event(.key(.control(.c), modifiers: []), copyBuffer: &copy) == .quit)
}

@Test func selectionCopyReusesStorageAtTheMaximumViewportSize() throws {
  let fixture = try SelectionFixture(String(repeating: "x", count: 9_600))
  var source = try PagedFileDocument.open(fixture.path)
  var viewport = try FileByteViewport()
  try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  let budget = viewport.storageBudgetBytes
  var copy = CopyBuffer()
  for _ in 0..<4 {
    viewport.copy(viewport.visibleRange, to: &copy)
    copy.flush { text in
      #expect(text.count == 9_600)
      #expect(String(copying: text) == String(repeating: "x", count: 9_600))
    }
    #expect(viewport.storageBudgetBytes == budget)
    #expect(viewport.byte(at: 0) == 0x78 && viewport.byte(at: 9_599) == 0x78)
    try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
  }
}

@Test func switchingMouseCaptureCancelsEdgeScrollingAndNeverResumesTheOldDrag() throws {
  let fixture = try SelectionFixture(String(repeating: "0123456789abcdef", count: 1_024))
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  try prepareViewer(viewer, in: size)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534))
  #expect(viewer.hasPendingWork && viewer.selectionRange != nil)

  let scrollbar = try #require(layout.scrollbarColumn)
  _ = viewer.mouse(.init(action: .press, button: .left, column: scrollbar, row: layout.text.y))
  #expect(!viewer.hasPendingWork && viewer.selectionRange == nil)
  _ = viewer.mouse(.init(action: .move, button: .left, column: 0, row: layout.text.bottom - 1))
  try prepareViewer(viewer, in: size)
  let anchor = viewer.firstByte
  #expect(anchor > 0)

  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: layout.text.x + 3, row: layout.text.y))
  _ = viewer.mouse(.init(action: .release, button: .left, column: layout.text.x + 3, row: layout.text.y))
  #expect(viewer.selectionRange == anchor..<anchor + 4)
  #expect(viewer.mouse(.init(action: .move, button: .left, column: 0, row: layout.text.y)) == .none)
  #expect(viewer.firstByte == anchor && !viewer.hasPendingWork)
}

@Test func selectionScrollsAtTheBottomWhileHeldAndCopiesOffscreenBytes() throws {
  let fixture = try SelectionFixture(String(repeating: "0123456789abcdef", count: 4_096))
  let viewer = try DocumentFileViewer(fixture.path, configuration: .init(pageBytes: 64, cachePages: 1))
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  try prepareViewer(viewer, in: size)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x + 2, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534))
  let start = ContinuousClock().now.advanced(by: .seconds(1))
  for step in 0..<4 {
    let now = start.advanced(by: .milliseconds(step * 50))
    #expect(viewer.performPendingWork(at: now) == .redraw)
    try prepareViewer(viewer, in: size)
    #expect(viewer.firstByte == layout.text.width * 3 * (step + 1))
    #expect(viewer.selectionRange?.lowerBound == 2)
    #expect(viewer.selectionRange?.upperBound == viewer.visibleRange.upperBound)
    #expect(viewer.performPendingWork(at: now) == .none)  // No busy-loop scrolling.
  }
  let range = try #require(viewer.selectionRange)
  #expect(range.lowerBound < viewer.visibleRange.lowerBound)
  _ = viewer.mouse(.init(action: .release, button: .left, column: 65_534, row: 65_534))
  #expect(!viewer.hasPendingWork)
  #expect(viewer.performPendingWork(at: start.advanced(by: .seconds(10))) == .none)
  var copy = CopyBuffer()
  #expect(viewer.copySelection(to: &copy) == .redraw)
  copy.flush { text in #expect(String(copying: text) == String(decoding: fixture.bytes[range], as: UTF8.self)) }
}

@Test func selectionScrollsUpAndStopsAtTheFileBoundaryBeyond64KiB() throws {
  let fixture = try SelectionFixture(String(repeating: "0123456789abcdef", count: 8_192))
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 160, rows: 60)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  try prepareViewer(viewer, in: size)
  _ = viewer.handle(.character("5"), modifiers: [])
  try prepareViewer(viewer, in: size)
  let first = viewer.firstByte
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.right - 1, row: layout.text.bottom - 1))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 0, row: 0))
  let start = ContinuousClock().now.advanced(by: .seconds(1))
  #expect(viewer.performPendingWork(at: start) == .redraw)
  try prepareViewer(viewer, in: size)
  // A history miss reconstructs rows from a page checkpoint. The first reverse
  // step may include a partial row when the byte jump landed inside that grid.
  #expect((1...3 * layout.text.width).contains(first - viewer.firstByte))
  #expect(viewer.selectionRange?.lowerBound == viewer.firstByte)
  _ = viewer.mouse(.init(action: .release, button: .left, column: 0, row: 0))
  #expect(!viewer.hasPendingWork)
  _ = viewer.handle(.home, modifiers: [])
  try prepareViewer(viewer, in: size)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534))
  let budgetBeforeCopy = viewer.storageBudgetBytes
  let maximumTicks = fixture.bytes.count / (3 * layout.text.width) + 1
  for step in 0..<maximumTicks {
    _ = viewer.performPendingWork(at: start.advanced(by: .milliseconds(step * 50)))
    try prepareViewer(viewer, in: size)
    #expect(viewer.storageBudgetBytes == budgetBeforeCopy)
  }
  #expect(viewer.selectionRange == 0..<fixture.bytes.count)
  #expect(!viewer.hasPendingWork)
  #expect(viewer.performPendingWork(at: start.advanced(by: .seconds(100))) == .none)
  var copy = CopyBuffer()
  #expect(viewer.copySelection(to: &copy) == .redraw)
  copy.flush { text in
    #expect(text.count == fixture.bytes.count)
    #expect(String(copying: text) == String(decoding: fixture.bytes, as: UTF8.self))
  }
  let budgetAfterCopy = viewer.storageBudgetBytes
  #expect(budgetAfterCopy >= budgetBeforeCopy + fixture.bytes.count)
  #expect(viewer.copySelection(to: &copy) == .redraw)
  copy.flush { text in #expect(text.count == fixture.bytes.count) }
  #expect(viewer.storageBudgetBytes == budgetAfterCopy)
}

@Test func failedOffscreenSelectionCopyPreservesThePendingHostCopy() throws {
  let fixture = try SelectionFixture(String(repeating: "a", count: 8_192))
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.bytes.count, showInspector: true)
  try prepareViewer(viewer, in: size)
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534))
  _ = viewer.performPendingWork(at: ContinuousClock().now.advanced(by: .seconds(1)))
  try prepareViewer(viewer, in: size)
  try #require(viewer.selectionRange!.lowerBound < viewer.visibleRange.lowerBound)
  let file = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
  try file.truncate(atOffset: 1)
  try file.close()
  var copy = CopyBuffer()
  copy.copy("pending".utf8Span)
  #expect(viewer.copySelection(to: &copy) == .redraw)
  #expect(viewer.notice.contains("File changed") && viewer.selectionRange == nil && !viewer.hasPendingWork)
  copy.flush { text in #expect(String(copying: text) == "pending") }
}

private func selectFirstRow(_ viewer: DocumentFileViewer, in layout: DocumentViewerLayout) {
  _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: layout.text.x + 4, row: layout.text.y))
  _ = viewer.mouse(.init(action: .release, button: .left, column: layout.text.x + 4, row: layout.text.y))
}

private struct SelectionFixture: ~Copyable {
  let path: String
  let bytes: [UInt8]
  init(_ text: String) throws {
    bytes = Array(text.utf8)
    path = NSTemporaryDirectory() + "slate-selection-" + UUID().uuidString
    try Data(bytes).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }
  deinit { try? FileManager.default.removeItem(atPath: path) }
}
