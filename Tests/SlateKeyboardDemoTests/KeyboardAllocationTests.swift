#if canImport(Darwin) || canImport(Glibc)
import CIOTestSupport
import Foundation
import Slate
import Testing

@testable import SlateKeyboardDemo

@Suite(.serialized)
struct KeyboardAllocationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func keyboardDemoAllocationAcrossTabsAndCapacityExhaustion() throws {
    try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")
    var app = SlateKeyboardDemo()
    app.controllerEnabled = false
    let size = SlateKeyboardDemo.configuration.maximumSize
    var surface = try Surface(maximumSize: size)
    // Full drafts exercise capacity rejection; the full word buffer also rejects
    // before mutation. Each tab renders the maximum viewport with reused owners.
    for _ in 0..<512 {
      app.predictive.type(97)
      app.common.type(98)
      app.chords.type(99)
    }
    for _ in 0..<4 { try keyboardBatch(&app, surface: &surface, size: size) }
    let budget = surface.storageBudgetBytes
    cli_test_begin_allocation_count()
    do throws(SurfaceError) {
      for _ in 0..<16 { try keyboardBatch(&app, surface: &surface, size: size) }
    } catch {
      _ = cli_test_end_allocation_count()
      throw error
    }
    let calls = cli_test_end_allocation_count()
    #expect(calls == 0)
    #expect(surface.storageBudgetBytes == budget)
    #expect(app.predictive.draft.count == 512 && app.common.draft.count == 512 && app.chords.draft.count == 512)
    print(
      "Keyboard: 64 tab/control-map frames at \(size.columns)x\(size.rows), full drafts/word rejection, \(calls) allocation calls"
    )
    print(
      "Inline text/candidate buffers: \(app.predictive.inlineStorageBudgetBytes * 3) bytes; lexicon budget: \(app.predictive.lexicon.storageBudgetBytes) bytes"
    )
  }

  @inline(never)
  private func keyboardBatch(_ app: inout SlateKeyboardDemo, surface: inout Surface, size: TerminalSize)
    throws(SurfaceError)
  {
    app.switchTo(.predictive)
    _ = app.receiveController(.init())
    _ = app.receiveController(.init(connected: true))
    _ = app.receiveController(.init(connected: true, leftX: 1, leftY: 1))
    _ = app.receiveController(.init(connected: true, leftX: 1, leftY: 1))
    _ = app.receiveController(.init(connected: true))
    _ = app.receiveController(.init(connected: true, buttons: .east))
    app.predictive.cancel()
    for _ in 0..<17 { app.chooseLeft(2) }
    app.predictive.finish()
    app.predictive.cancel()
    for sector in [2, 1, 3, 3, 4] { app.chooseLeft(sector) }
    app.predictive.finish()
    try surface.render(size: size) { app.render(in: size) }
    app.switchTo(.common)
    app.common.moreLetters = true
    for sector in 0..<8 {
      app.chooseLeft(sector)
      app.chooseRight(0)
    }
    try surface.render(size: size) { app.render(in: size) }
    app.switchTo(.chords)
    _ = app.receiveController(.init(connected: true))
    _ = app.receiveController(.init(connected: true, leftY: 1, rightX: 1))
    _ = app.receiveController(.init(connected: true, leftY: 1))
    for sector in 0..<8 {
      app.chooseLeft(sector)
      app.chooseRight(6)
    }
    try surface.render(size: size) { app.render(in: size) }
    app.showsControls = true
    app.controlsDrawing.snapshot = .init(
      connected: true, buttons: .standard.union([.touchpad, .microphoneMute]),
      leftX: -1, leftY: 1, rightX: 0.5, rightY: -0.5, leftTrigger: 1, rightTrigger: 0.5,
      supportedButtons: .standard.union([.touchpad, .microphoneMute]),
      features: [.rightStick, .touchPositions, .touchContacts],
      primaryTouch: .init(isTouching: true), secondaryTouch: .init(x: 1, y: -1, isTouching: true))
    try surface.render(size: size) { app.render(in: size) }
    app.showsControls = false
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func keyboardDemoAllocationForWarmedMaximumClipboardCopies() throws {
    try #require(cli_test_prepare_allocation_counter() != 0)
    var app = SlateKeyboardDemo()
    app.controllerEnabled = false
    for _ in 0..<512 { app.predictive.type(97) }
    var copy = CopyBuffer()
    for _ in 0..<4 {
      _ = app.receiveController(.init(connected: true))
      _ = app.receiveController(.init(connected: true, buttons: .create))
      app.fulfillCopyRequest(into: &copy)
      copy.flush { _ = $0.count }
    }
    var byteCount = 0
    cli_test_begin_allocation_count()
    for _ in 0..<1_000 {
      _ = app.receiveController(.init(connected: true))
      _ = app.receiveController(.init(connected: true, buttons: .create))
      app.fulfillCopyRequest(into: &copy)
      copy.flush { byteCount += $0.count }
    }
    let calls = cli_test_end_allocation_count()
    #expect(calls == 0 && byteCount == 512_000)
    print("Keyboard clipboard: 1,000 warmed 512-byte copies, \(calls) allocation calls")
  }
}
#endif
