import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func documentViewerWrapsBytesAndMarksOnlyRevealedRows() throws {
  let text = String(repeating: "0123456789abcdef", count: 1_024)
  let fixture = try ViewerFixture(text)
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: text.utf8.count, showInspector: true)
  var surface = try Surface(maximumSize: size)
  try prepareViewer(viewer, in: size)
  #expect(viewer.lastPageLoads == 1 && viewer.lastBytesRead == 16_384)
  #expect(viewer.visibleRange == 0..<layout.text.width * layout.text.height)
  try surface.render(size: size) { frame in
    viewer.paint(in: &frame)
    #expect(rowText(frame, y: layout.text.y, x: layout.text.x, width: 16) == "0123456789abcdef")
    #expect(rowText(frame, y: layout.text.y, x: 2, width: layout.gutterDigits) == "    0")
    #expect(frame[layout.text.x, layout.text.y].style.underlined)
    #expect(rowText(frame, y: size.rows - 1, x: size.columns - 15, width: 14) == "? help  Q quit")
  }
  #expect(viewer.handle(.down, modifiers: []) == .redraw)
  try prepareViewer(viewer, in: size)
  #expect(viewer.lastPageLoads == 0 && viewer.lastBytesRead == 0 && viewer.lastCacheHits == 1)
  #expect(viewer.firstByte == layout.text.width)
  try surface.render(size: size) { frame in
    viewer.paint(in: &frame)
    #expect(frame[1, layout.text.y].glyph.scalar == " ")
    #expect(frame[1, layout.text.bottom - 1].glyph.scalar == ">")
    #expect(frame[layout.text.x, layout.text.bottom - 1].style.background == .indexed(236))
  }
  _ = viewer.handle(.up, modifiers: [])
  try prepareViewer(viewer, in: size)
  try surface.render(size: size) { frame in
    viewer.paint(in: &frame)
    #expect(frame[1, layout.text.y].glyph.scalar == ">")
    #expect(frame[1, layout.text.bottom - 1].glyph.scalar == " ")
  }
  _ = viewer.handle(.end, modifiers: [])
  try prepareViewer(viewer, in: size)
  #expect(viewer.visibleRange.upperBound == text.utf8.count)
  try surface.render(size: size) { frame in
    viewer.paint(in: &frame)
    #expect(frame[layout.scrollbarColumn!, layout.text.bottom - 1].glyph.scalar == "┃")
    #expect(rowText(frame, y: size.rows - 4, x: 39, width: 4) == "100%")
  }
}

@Test func documentViewerJumpsEvictsClearsAndKeepsHelpOutOfReadStatistics() throws {
  let fixture = try ViewerFixture(String(repeating: "0123456789abcdef", count: 4_096))
  let viewer = try DocumentFileViewer(fixture.path, configuration: .init(pageBytes: 1_024, cachePages: 2))
  let size = TerminalSize(columns: 112, rows: 24)
  try prepareViewer(viewer, in: size)
  let budget = viewer.storageBudgetBytes
  _ = viewer.handle(.character("9"), modifiers: [])
  try prepareViewer(viewer, in: size)
  #expect(viewer.firstByte == 65_535 * 9 / 10)
  #expect(viewer.lastPageLoads > 0 && viewer.lastEvictions > 0)
  #expect(viewer.lastBytesRead == viewer.lastPageLoads * 1_024)
  _ = viewer.handle(.character("]"), modifiers: [])
  try prepareViewer(viewer, in: size)
  #expect(viewer.firstByte == 58 * 1_024)
  _ = viewer.handle(.character("["), modifiers: [])
  try prepareViewer(viewer, in: size)
  #expect(viewer.firstByte == 57 * 1_024)
  _ = viewer.handle(.down, modifiers: [])
  try prepareViewer(viewer, in: size)
  _ = viewer.handle(.character("["), modifiers: [])
  try prepareViewer(viewer, in: size)
  #expect(viewer.firstByte == 57 * 1_024)
  let stats = viewer.statistics
  _ = viewer.handle(.character("?"), modifiers: [])
  try prepareViewer(viewer, in: size)
  #expect(viewer.helpVisible && viewer.statistics == stats)
  #expect(viewer.handle(.escape, modifiers: []) == .redraw && !viewer.helpVisible)
  _ = viewer.handle(.character("C"), modifiers: [])
  try prepareViewer(viewer, in: size)
  #expect(viewer.lastPageLoads > 0 && viewer.lastEvictions == 0)
  #expect(viewer.storageBudgetBytes == budget)
  #expect(viewer.handle(.control(.c), modifiers: []) == .quit)
  #expect(viewer.handle(.escape, modifiers: []) == .quit)
}

@Test func documentViewerResponsiveLayoutsAndResizePreserveByteAnchor() throws {
  let fixture = try ViewerFixture(String(repeating: "0123456789abcdef", count: 1_024))
  let viewer = try DocumentFileViewer(fixture.path)
  let maximum = TerminalSize(columns: 160, rows: 60)
  try prepareViewer(viewer, in: maximum)
  _ = viewer.handle(.character("5"), modifiers: [])
  try prepareViewer(viewer, in: maximum)
  let anchor = viewer.firstByte
  var surface = try Surface(maximumSize: maximum)
  for size in [
    TerminalSize(columns: 0, rows: 0), .init(columns: 1, rows: 1), .init(columns: 16, rows: 7),
    .init(columns: 40, rows: 7), .init(columns: 48, rows: 14), .init(columns: 80, rows: 24),
    .init(columns: 100, rows: 22), maximum
  ] {
    let layout = DocumentViewerLayout(size: size, byteCount: 16_384, showInspector: true)
    #expect(layout.text.right <= size.columns && layout.text.bottom <= size.rows)
    if let inspector = layout.inspector {
      #expect(inspector.right <= size.columns && inspector.bottom <= size.rows)
      #expect(layout.document.right < inspector.x)
    }
    try prepareViewer(viewer, in: size)
    #expect(viewer.firstByte == anchor)
    let beforePaint = viewer.statistics
    try surface.render(size: size) { viewer.paint(in: &$0) }
    #expect(viewer.statistics == beforePaint)
    _ = viewer.handle(.character("?"), modifiers: [])
    try surface.render(size: size) { viewer.paint(in: &$0) }
    _ = viewer.handle(.escape, modifiers: [])
  }
  _ = viewer.handle(.character("I"), modifiers: [])
  try prepareViewer(viewer, in: maximum)
  #expect(viewer.firstByte == anchor)
  _ = viewer.handle(.character("0"), modifiers: [])
  try prepareViewer(viewer, in: maximum)
  #expect(viewer.firstByte == 0)
}

@Test func documentViewerEmptyFileHasNoReadsAndCanNavigate() throws {
  let fixture = try ViewerFixture("")
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  for key in [InputKey.down, .up, .pageDown, .pageUp, .end, .home, .character("9"), .character("]"), .character("[")] {
    _ = viewer.handle(key, modifiers: [])
    try prepareViewer(viewer, in: size)
    #expect(viewer.firstByte == 0 && viewer.visibleRange.isEmpty && viewer.lastPageLoads == 0)
  }
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { viewer.paint(in: &$0) }
}

@Test func documentViewerNavigatesAndCopiesBinaryBytesAcrossEvictions() throws {
  let bytes = (0..<16_384).map { UInt8($0 % 256) }
  let fixture = try ViewerFixture(bytes)
  let viewer = try DocumentFileViewer(
    fixture.path, configuration: .init(pageBytes: 64, cachePages: 1, maximumPages: 256))
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: bytes.count, showInspector: true)
  var surface = try Surface(maximumSize: size)
  let budget = viewer.storageBudgetBytes
  for key in [InputKey.home, .down, .pageDown, .end, .character("C"), .home] {
    _ = viewer.handle(key, modifiers: [])
    try prepareViewer(viewer, in: size)
    #expect(viewer.notice.isEmpty && viewer.storageBudgetBytes == budget)
    if key == .end { #expect(viewer.visibleRange.upperBound == bytes.count) }
    let statistics = viewer.statistics
    try surface.render(size: size) { frame in
      viewer.paint(in: &frame)
      for index in 0..<viewer.visibleRange.count {
        let byte = bytes[viewer.visibleRange.lowerBound + index]
        let scalar = (0x20...0x7e).contains(byte) ? Unicode.Scalar(byte) : "."
        let column = layout.text.x + index % layout.text.width
        let row = layout.text.y + index / layout.text.width
        #expect(frame[column, row].glyph.scalar == scalar)
      }
    }
    #expect(viewer.statistics == statistics)
  }
  #expect(viewer.statistics.evictions > 0)
  var copy = CopyBuffer()
  // Exercise both the viewport scratch copy and the offscreen file-read copy.
  for offscreen in [false, true] {
    _ = viewer.handle(.home, modifiers: [])
    try prepareViewer(viewer, in: size)
    try #require(viewer.firstByte == 0)
    _ = viewer.mouse(.init(action: .press, button: .left, column: layout.text.x, row: layout.text.y))
    _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: layout.text.bottom - 1))
    if offscreen {
      _ = viewer.performPendingWork(at: ContinuousClock().now.advanced(by: .seconds(1)))
      try prepareViewer(viewer, in: size)
    }
    _ = viewer.mouse(.init(action: .release, button: .left, column: 65_534, row: layout.text.bottom - 1))
    let range = try #require(viewer.selectionRange)
    #expect((range.lowerBound < viewer.visibleRange.lowerBound) == offscreen)
    #expect(viewer.copySelection(to: &copy) == .redraw && viewer.notice.isEmpty)
    var delivered = false
    copy.flush { text in
      delivered = true
      let expected = bytes[range].map { (0x20...0x7e).contains($0) ? $0 : 0x2e }
      #expect(String(copying: text) == String(decoding: expected, as: UTF8.self))
    }
    #expect(delivered)
  }
}

private func rowText(_ frame: borrowing Frame, y: Int, x: Int, width: Int) -> String {
  var result = ""
  for column in x..<(x + width) { result.unicodeScalars.append(frame[column, y].glyph.scalar) }
  return result
}

private struct ViewerFixture: ~Copyable {
  let path: String
  init(_ text: String) throws {
    try self.init(Array(text.utf8))
  }
  init(_ bytes: [UInt8]) throws {
    path = NSTemporaryDirectory() + "slate-viewer-" + UUID().uuidString
    try Data(bytes).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }
  deinit { try? FileManager.default.removeItem(atPath: path) }
}
