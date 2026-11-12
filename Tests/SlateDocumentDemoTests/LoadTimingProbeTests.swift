import Foundation
import Testing

@testable import SlateDocumentDemo

@Test func loadTimingProbe() throws {
  let path = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("pi_hex_1b.txt").path
  let clock = ContinuousClock()
  let start = clock.now
  var indexer = try PagedFileDocument.Indexer(path, content: .bytes)
  for _ in 0..<256 { try indexer.advance(maximumPages: 1) }
  print("LOAD PROBE: \(indexer.indexedByteCount) bytes in \(start.duration(to: clock.now))")
}
