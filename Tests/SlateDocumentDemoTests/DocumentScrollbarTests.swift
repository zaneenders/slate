import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

@Test func documentScrollbarMapsEveryRowAndClampsAtBothEnds() throws {
  let size = TerminalSize(columns: 80, rows: 24)
  for byteCount in [4_096, 1_000_000_002, 1_099_511_627_776] {
    let layout = DocumentViewerLayout(size: size, byteCount: byteCount, showInspector: true)
    let visible = layout.text.width * layout.text.height
    let bar = try #require(DocumentScrollbar(layout: layout, byteCount: byteCount, visibleBytes: visible, firstByte: 0))
    #expect(bar.canDrag)
    #expect(bar.byteOffset(pointerRow: 0, grabOffsetRows: 0) == 0)
    #expect(bar.byteOffset(pointerRow: 65_534, grabOffsetRows: 0) == byteCount - visible)
    for top in 0...bar.travelRows {
      let offset = bar.byteOffset(pointerRow: bar.firstRow + top, grabOffsetRows: 0)
      let mapped = try #require(
        DocumentScrollbar(layout: layout, byteCount: byteCount, visibleBytes: visible, firstByte: offset))
      #expect(mapped.thumbFirstRow == bar.firstRow + top)
    }
  }
  for byteCount in [0, 1, 100] {
    let layout = DocumentViewerLayout(size: size, byteCount: byteCount, showInspector: true)
    let bar = try #require(
      DocumentScrollbar(
        layout: layout, byteCount: byteCount,
        visibleBytes: layout.text.width * layout.text.height, firstByte: 0))
    #expect(!bar.canDrag && bar.thumbRows == bar.rowCount)
    #expect(bar.byteOffset(pointerRow: 65_534, grabOffsetRows: 0) == 0)
  }
}

@Test func documentScrollbarDragsOutsideTrackAndReleasesWithoutReadingInHandlers() throws {
  let fixture = try ScrollFixture(count: 65_536)
  let viewer = try DocumentFileViewer(fixture.path, configuration: .init(pageBytes: 1_024, cachePages: 2))
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.count, showInspector: true)
  viewer.prepare(in: size)
  let x = try #require(layout.scrollbarColumn)
  let beforeMouse = viewer.statistics
  #expect(viewer.mouse(.init(action: .press, button: .left, column: x, row: layout.text.y)) == .redraw)
  #expect(viewer.firstByte == 0)
  #expect(viewer.mouse(.init(action: .move, button: .left, column: 0, row: 65_534)) == .redraw)
  #expect(viewer.firstByte == fixture.count - layout.text.width * layout.text.height)
  #expect(viewer.statistics == beforeMouse)
  viewer.prepare(in: size)
  #expect(viewer.visibleRange.upperBound == fixture.count && viewer.lastPageLoads > 0)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { frame in
    viewer.paint(in: &frame)
    #expect(frame[x, layout.text.bottom - 1].glyph.scalar == "┃")
    #expect(frame[x, layout.text.bottom - 1].style.foreground == .indexed(114))
  }
  #expect(viewer.mouse(.init(action: .move, button: .left, column: 0, row: 0)) == .redraw)
  #expect(viewer.firstByte == 0)
  #expect(viewer.mouse(.init(action: .release, button: .left, column: 0, row: 0)) == .redraw)
  #expect(viewer.mouse(.init(action: .move, button: .left, column: x, row: layout.text.bottom - 1)) == .none)
  #expect(viewer.firstByte == 0)
  viewer.prepare(in: size)
  try surface.render(size: size) { frame in
    viewer.paint(in: &frame)
    #expect(frame[x, layout.text.y].style.foreground == .indexed(81))
  }
}

@Test func documentScrollbarThumbGrabPreservesOffsetAndTrackClickJumps() throws {
  let fixture = try ScrollFixture(count: 4_096)
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.count, showInspector: true)
  viewer.prepare(in: size)
  _ = viewer.handle(.character("3"), modifiers: [])
  viewer.prepare(in: size)
  let offset = viewer.firstByte
  let bar = try #require(
    DocumentScrollbar(
      layout: layout, byteCount: fixture.count,
      visibleBytes: viewer.visibleRange.count, firstByte: offset))
  try #require(bar.thumbRows > 1)
  let row = bar.thumbFirstRow + bar.thumbRows - 1
  _ = viewer.mouse(.init(action: .press, button: .left, column: bar.column, row: row))
  #expect(viewer.firstByte == offset)
  #expect(viewer.mouse(.init(action: .move, button: .left, column: 0, row: row)) == .none)
  _ = viewer.mouse(.init(action: .release, button: .left, column: 0, row: row))
  #expect(viewer.firstByte == offset)
  _ = viewer.mouse(.init(action: .press, button: .left, column: bar.column, row: layout.text.bottom - 1))
  viewer.prepare(in: size)
  #expect(viewer.visibleRange.upperBound == fixture.count)
  _ = viewer.mouse(.init(action: .release, button: .left, column: bar.column, row: layout.text.bottom - 1))
  _ = viewer.mouse(.init(action: .press, button: .left, column: bar.column, row: layout.text.y))
  #expect(viewer.firstByte == 0)
}

@Test func documentScrollbarIgnoresOtherAreasAndCancelsForResizeHelpAndLostRelease() throws {
  let fixture = try ScrollFixture(count: 16_384)
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.count, showInspector: true)
  let x = try #require(layout.scrollbarColumn)
  #expect(viewer.mouse(.init(action: .press, button: .left, column: x, row: 10)) == .none)
  viewer.prepare(in: size)
  for event in [
    MouseEvent(action: .press, button: .right, column: x, row: layout.text.y),
    .init(action: .press, button: .left, column: x - 1, row: layout.text.y),
    .init(action: .press, button: .left, column: x, row: 0),
    .init(action: .press, button: .left, column: x, row: layout.text.y, modifiers: .control)
  ] {
    #expect(viewer.mouse(event) == .none && viewer.firstByte == 0)
  }
  _ = viewer.mouse(.init(action: .press, button: .left, column: x, row: layout.text.y))
  _ = viewer.mouse(.init(action: .move, column: x, row: layout.text.y + 1))  // Button no longer held.
  #expect(viewer.mouse(.init(action: .move, button: .left, column: x, row: layout.text.bottom - 1)) == .none)
  #expect(viewer.firstByte == 0)
  _ = viewer.mouse(.init(action: .press, button: .left, column: x, row: layout.text.y))
  viewer.prepare(in: .init(columns: 112, rows: 30))
  #expect(viewer.mouse(.init(action: .move, button: .left, column: x, row: 29)) == .none)
  #expect(viewer.firstByte == 0)
  _ = viewer.handle(.character("?"), modifiers: [])
  #expect(viewer.mouse(.init(action: .press, button: .left, column: x, row: 20)) == .none)
  #expect(viewer.firstByte == 0)
}

@Test func documentScrollbarHandlesNoTrackFullThumbAndWheelBoundaries() throws {
  let small = try ScrollFixture(count: 32)
  let smallViewer = try DocumentFileViewer(small.path)
  smallViewer.prepare(in: .init(columns: 80, rows: 24))
  #expect(smallViewer.mouse(.init(action: .press, button: .left, column: 78, row: 10)) == .none)
  let fixture = try ScrollFixture(count: 16_384)
  let viewer = try DocumentFileViewer(fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.count, showInspector: true)
  viewer.prepare(in: size)
  #expect(viewer.mouse(.init(action: .scrollUp, column: 10, row: layout.text.y)) == .none)
  #expect(viewer.mouse(.init(action: .scrollDown, column: 10, row: layout.text.y)) == .redraw)
  #expect(viewer.firstByte == layout.text.width * 3)
  #expect(viewer.mouse(.init(action: .scrollUp, column: 10, row: layout.text.y)) == .redraw)
  #expect(viewer.firstByte == 0)
  viewer.prepare(in: .init(columns: 31, rows: 7))
  #expect(viewer.mouse(.init(action: .press, button: .left, column: 30, row: 3)) == .none)
  viewer.prepare(in: .init(columns: 40, rows: 6))  // A one-row track cannot move a thumb.
  #expect(viewer.mouse(.init(action: .press, button: .left, column: 39, row: 2)) == .none)
}

@Test func documentDemoForwardsScrollbarInputOnlyAfterIndexing() throws {
  let fixture = try ScrollFixture(count: 16_384)
  var application = SlateDocumentDemo(path: fixture.path)
  let size = TerminalSize(columns: 80, rows: 24)
  let layout = DocumentViewerLayout(size: size, byteCount: fixture.count, showInspector: true)
  let x = try #require(layout.scrollbarColumn)
  let press = MouseEvent(action: .press, button: .left, column: x, row: layout.text.y)
  var copy = CopyBuffer()
  #expect(SlateDocumentDemo.configuration.mouseTracking)
  #expect(application.event(.mouse(press), copyBuffer: &copy) == .none)
  _ = application.performPendingWork()
  try #require(!application.hasPendingWork)
  _ = application.render(in: size)
  #expect(application.event(.mouse(press), copyBuffer: &copy) == .redraw)
  #expect(
    application.event(.mouse(.init(action: .move, button: .left, column: 0, row: 65_534)), copyBuffer: &copy) == .redraw
  )
  _ = application.event(.mouse(.init(action: .release, button: .left, column: 0, row: 65_534)), copyBuffer: &copy)
  _ = application.render(in: size)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { application.paint(in: &$0) }
  let percent = (39..<43).map { surface.cell(x: $0, y: size.rows - 4)!.glyph.scalar }.map(String.init).joined()
  #expect(percent == "100%")
}

private struct ScrollFixture: ~Copyable {
  let path: String
  let count: Int
  init(count: Int) throws {
    self.count = count
    path = NSTemporaryDirectory() + "slate-scroll-" + UUID().uuidString
    try Data(repeating: 0x61, count: count).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
  }
  deinit { try? FileManager.default.removeItem(atPath: path) }
}
