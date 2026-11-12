import Slate
import Testing

@testable import SlateDocumentDemo

func prepareViewer(_ viewer: DocumentFileViewer, in size: TerminalSize) throws {
  viewer.prepare(in: size)
  try finishViewportPreparation(viewer)
}

func finishViewportPreparation(_ viewer: DocumentFileViewer) throws {
  for _ in 0..<65_536 {
    if !viewer.isPreparingViewport { return }
    _ = viewer.performPendingWork()
  }
  Issue.record("Viewport preparation exceeded the bounded replay workload")
  try #require(!viewer.isPreparingViewport)
}

func finishApplicationWork(_ application: inout SlateDocumentDemo, size: TerminalSize) throws {
  for _ in 0..<4_096 {
    _ = application.render(in: size)
    if !application.hasPendingWork { return }
    _ = application.performPendingWork()
  }
  try #require(!application.hasPendingWork)
}
