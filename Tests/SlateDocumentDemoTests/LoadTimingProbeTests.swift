import Foundation
import Testing

@testable import SlateDocumentDemo

/// SLATE_RUN_LOAD_BENCHMARK=1 swift test -c release --filter loadTimingProbe
/// SLATE_LARGE_DOCUMENT_PATH optionally selects an existing fixture.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_RUN_LOAD_BENCHMARK"] == "1"))
func loadTimingProbe() throws {
  let defaultPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("pi_hex_1b.txt").path
  let path = ProcessInfo.processInfo.environment["SLATE_LARGE_DOCUMENT_PATH"] ?? defaultPath
  let clock = ContinuousClock()
  let start = clock.now
  var indexer = try PagedFileDocument.Indexer(path, content: .bytes)
  for _ in 0..<256 {
    try indexer.advance(maximumPages: 1)
    if indexer.isComplete { break }
  }
  print("LOAD PROBE: \(indexer.indexedByteCount) bytes in \(start.duration(to: clock.now))")
}
