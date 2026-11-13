#if canImport(Darwin)
import CIOTestSupport
import Foundation
import Slate
import Testing

@testable import SlateGraphicsDemo

/// Setup, runtime warm-up, clocks, and assertions stay outside the synchronous
/// measured loop. Each event replaces fixed-size state and renders the full demo.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
func graphicsDragAllocationAtMaximumViewport() throws {
  try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")
  let configuration = SlateGraphicsDemo.configuration
  let size = configuration.maximumSize
  var application = SlateGraphicsDemo()
  var copy = CopyBuffer()
  var surface = try Surface(maximumSize: size)
  _ = application.event(.key(.character(" ")), copyBuffer: &copy)
  try surface.render(size: size) { application.render(in: size) }
  let initial = application.overlayBounds
  _ = application.event(
    .mouse(.init(action: .press, button: .left, column: initial.x + 4, row: initial.y)), copyBuffer: &copy)
  for step in 0..<4 {
    try renderDragStep(step, application: &application, surface: &surface, copy: &copy, size: size)
  }
  let budget = surface.storageBudgetBytes
  cli_test_begin_allocation_count()
  do throws(SurfaceError) {
    for step in 0..<32 {
      try renderDragStep(step, application: &application, surface: &surface, copy: &copy, size: size)
    }
  } catch {
    _ = cli_test_end_allocation_count()
    throw error
  }
  let calls = cli_test_end_allocation_count()
  #expect(calls == 0)
  #expect(surface.storageBudgetBytes == budget)
  #expect(application.isPaused && application.isDraggingOverlay)
  #expect(surface.cell(x: application.overlayBounds.x, y: application.overlayBounds.y)?.glyph.scalar == "┌")
  print("Graphics drag: 32 frames at \(size.columns)x\(size.rows), \(calls) allocation calls")

  _ = application.event(.key(.character(" ")), copyBuffer: &copy)
  for _ in 0..<4 { try renderAnimationStep(application: &application, surface: &surface, copy: &copy, size: size) }
  let phase = application.animationPhase
  cli_test_begin_allocation_count()
  do throws(SurfaceError) {
    for _ in 0..<32 { try renderAnimationStep(application: &application, surface: &surface, copy: &copy, size: size) }
  } catch {
    _ = cli_test_end_allocation_count()
    throw error
  }
  let animationCalls = cli_test_end_allocation_count()
  #expect(animationCalls == 0)
  #expect(surface.storageBudgetBytes == budget)
  #expect(application.animationPhase == (phase + 32) % 64)
  print("Graphics ticks: 32 animated frames, \(animationCalls) allocation calls")
}

@inline(never)
private func renderDragStep(
  _ step: Int, application: inout SlateGraphicsDemo, surface: inout Surface, copy: inout CopyBuffer,
  size: TerminalSize
) throws(SurfaceError) {
  _ = application.event(
    .mouse(.init(action: .move, button: .left, column: 24 + step % 2 * 120, row: 10 + step % 2 * 40)),
    copyBuffer: &copy)
  try surface.render(size: size) { application.render(in: size) }
}

@inline(never)
private func renderAnimationStep(
  application: inout SlateGraphicsDemo, surface: inout Surface, copy: inout CopyBuffer, size: TerminalSize
) throws(SurfaceError) {
  _ = application.event(.tick(elapsed: .milliseconds(16)), copyBuffer: &copy)
  try surface.render(size: size) { application.render(in: size) }
}
#endif
