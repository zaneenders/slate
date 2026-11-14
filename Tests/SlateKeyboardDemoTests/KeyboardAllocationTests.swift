#if canImport(Darwin) || canImport(Glibc)
import CIOTestSupport
import Foundation
import Slate
import Testing

@testable import SlateKeyboardDemo

@Suite(.serialized)
struct KeyboardAllocationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func keyboardDemoAllocationForRenderingCapacityRejectionAndClipboard() throws {
    try #require(cli_test_prepare_allocation_counter() != 0)
    var app = SlateKeyboardDemo()
    app.controllerEnabled = false
    try app.draft.insert(String(repeating: "a", count: 512).utf8Span)
    var surface = try Surface(maximumSize: SlateKeyboardDemo.configuration.maximumSize)
    var copy = CopyBuffer()
    for _ in 0..<4 { try batch(&app, surface: &surface, copy: &copy) }
    let budget = surface.storageBudgetBytes
    cli_test_begin_allocation_count()
    do throws(SurfaceError) {
      for _ in 0..<32 { try batch(&app, surface: &surface, copy: &copy) }
    } catch {
      _ = cli_test_end_allocation_count()
      throw error
    }
    let calls = cli_test_end_allocation_count()
    #expect(calls == 0)
    #expect(app.draft.byteCount == 512)
    #expect(surface.storageBudgetBytes == budget)
  }

  private func batch(_ app: inout SlateKeyboardDemo, surface: inout Surface, copy: inout CopyBuffer)
    throws(SurfaceError)
  {
    _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true, buttons: .west), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true, leftY: 1, rightY: 1), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true, leftY: 1, rightY: 1), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true, buttons: .south), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true), copyBuffer: &copy)
    _ = app.receiveController(.init(connected: true, buttons: .create), copyBuffer: &copy)
    copy.flush { _ = $0.count }
    let size = surface.maximumSize
    try surface.render(size: size) { app.render(in: size) }
  }
}
#endif
