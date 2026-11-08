import Foundation
import Slate
import Testing

@testable import SlateDocumentDemo

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
import Musl
#endif

/// Pair retained release test binaries against the same immutable file. Include
/// ordinary row scrolling, direction changes, and reverse history exhaustion.
@Test func fileBackwardScrollProfile() throws {
  guard let path = ProcessInfo.processInfo.environment["SLATE_BACKWARD_SCROLL_PROFILE_PATH"] else { return }
  let viewer = try DocumentFileViewer(path)
  let size = TerminalSize(columns: 160, rows: 60)
  let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
  let fileBytes = Int(try file.seekToEnd())
  try file.close()
  let layout = DocumentViewerLayout(size: size, byteCount: fileBytes, showInspector: true)
  var surface = try Surface(maximumSize: size)
  _ = viewer.handle(.character("5"), modifiers: [])
  viewer.prepare(in: size)
  try finishUnicodePreparation(viewer)
  let budget = viewer.storageBudgetBytes
  let before = viewer.statistics
  let clock = ContinuousClock()
  var samples: [Duration] = []
  samples.reserveCapacity(120)
  var batches = 0
  var digest: UInt64 = 14_695_981_039_346_656_037
  for step in 0..<120 {
    let start = clock.now
    _ = viewer.mouse(
      .init(
        action: step < 40 ? .scrollDown : .scrollUp, button: .none,
        column: layout.text.x, row: layout.text.y))
    viewer.prepare(in: size)
    for _ in 0..<65_536 {
      if !viewer.isPreparingViewport { break }
      _ = viewer.performPendingWork()
      batches += 1
    }
    try #require(!viewer.isPreparingViewport && viewer.notice.isEmpty)
    try surface.render(size: size) { viewer.paint(in: &$0) }
    samples.append(start.duration(to: clock.now))
    // Include every rendered glyph and navigation result outside the timed step.
    digest = (digest ^ UInt64(viewer.firstByte)) &* 1_099_511_628_211
    for row in layout.text.y..<layout.text.bottom {
      for column in layout.text.x..<layout.text.right {
        let glyph = try #require(surface.cell(x: column, y: row)?.glyph)
        let text = glyph.utf8()
        let bytes = text.span
        for index in 0..<bytes.count { digest = (digest ^ UInt64(bytes[index])) &* 1_099_511_628_211 }
      }
    }
  }
  #expect(viewer.storageBudgetBytes == budget)
  let downward = samples.prefix(40).reduce(Duration.zero, +)
  let upward = samples.suffix(80).reduce(Duration.zero, +)
  samples.sort()
  let total = samples.reduce(Duration.zero, +)
  let slow = samples.filter { $0 > .milliseconds(16) }.count
  print(
    "backward-scroll-profile actions=120 down_total=\(downward) up_total=\(upward) total=\(total) median=\(samples[60]) p95=\(samples[114]) maximum=\(samples[119]) over_16ms=\(slow) batches=\(batches) loads=\(viewer.statistics.loads - before.loads) digest=\(digest) storage_bytes=\(budget)"
  )
}

/// Opt-in real-file workload. Run the same release test binary on both revisions
/// with SLATE_DOCUMENT_PROFILE_PATH set; normal tests never read a large fixture.
@Test func fileReaderProfile() throws {
  guard let path = ProcessInfo.processInfo.environment["SLATE_DOCUMENT_PROFILE_PATH"] else { return }
  let clock = ContinuousClock()
  let start = clock.now
  var source = try PagedFileDocument.open(path)
  let opened = clock.now
  var buffer = InlineArray<9_600, UInt8>(repeating: 0)
  var digest: UInt64 = 14_695_981_039_346_656_037
  for step in 0..<256 {
    let offset = max(0, source.byteCount - buffer.count) * step / 255
    let requested = min(buffer.count, source.byteCount - offset)
    var count = 0
    while count < requested {
      var storage = buffer.mutableSpan
      let copied = try source.readUTF8(
        from: offset + count, into: storage._mutatingExtracting(count..<requested))
      #expect(copied > 0)
      guard copied > 0 else { return }
      count += copied
    }
    for index in 0..<count { digest = (digest ^ UInt64(buffer[index])) &* 1_099_511_628_211 }
  }
  let finished = clock.now
  print(
    "document-profile open=\(start.duration(to: opened)) reads=\(opened.duration(to: finished)) digest=\(digest) loads=\(source.statistics.loads) cache_bytes=\(source.cacheStorageBudgetBytes)"
  )
}

/// Real-file correctness and navigation timing, separate from the matching
/// before/after reader workload above. The oracle reads at most one viewport.
@Test func fileViewerProfile() throws {
  guard let path = ProcessInfo.processInfo.environment["SLATE_DOCUMENT_PROFILE_PATH"] else { return }
  let viewer = try DocumentFileViewer(path)
  let size = TerminalSize(columns: 160, rows: 60)
  let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
  defer { try? handle.close() }
  let fileBytes = Int(try handle.seekToEnd())
  let layout = DocumentViewerLayout(size: size, byteCount: fileBytes, showInspector: true)
  var surface = try Surface(maximumSize: size)
  let clock = ContinuousClock()
  var maximumDuration = Duration.zero
  var totalDuration = Duration.zero
  for key in [
    InputKey.character("0"), .character("5"), .character("9"), .end, .up,
    .pageUp, .pageDown, .character("["), .character("]"), .character("C"), .home
  ] {
    let start = clock.now
    _ = viewer.handle(key, modifiers: [])
    viewer.prepare(in: size)
    try surface.render(size: size) { viewer.paint(in: &$0) }
    let elapsed = start.duration(to: clock.now)
    totalDuration += elapsed
    maximumDuration = max(maximumDuration, elapsed)
    try handle.seek(toOffset: UInt64(viewer.visibleRange.lowerBound))
    let reference = try handle.read(upToCount: viewer.visibleRange.count) ?? Data()
    #expect(reference.count == viewer.visibleRange.count)
    for (index, byte) in reference.enumerated() {
      let scalar = (0x20...0x7e).contains(byte) ? Unicode.Scalar(byte) : "."
      #expect(
        surface.cell(
          x: layout.text.x + index % layout.text.width,
          y: layout.text.y + index / layout.text.width)?.glyph.scalar == scalar)
    }
    if key == .end { #expect(viewer.visibleRange.upperBound == fileBytes) }
  }
  print(
    "viewer-profile actions=11 total=\(totalDuration) maximum=\(maximumDuration) working_storage_bytes=\(viewer.storageBudgetBytes)"
  )
}

@Test func fileIndexingUIProfile() throws {
  guard let path = ProcessInfo.processInfo.environment["SLATE_DOCUMENT_PROFILE_PATH"] else { return }
  let clock = ContinuousClock()
  let start = clock.now
  var application = SlateDocumentDemo(path: path)
  let progress = try #require(application.indexingProgress)
  #expect(progress.indexedBytes == 0 && application.hasPendingWork)
  let size = TerminalSize(columns: 160, rows: 60)
  var surface = try Surface(maximumSize: size)
  _ = application.render(in: size)
  try surface.render(size: size) { application.paint(in: &$0) }
  let firstFrame = start.duration(to: clock.now)
  var frames = 1
  for _ in 0...progress.totalPages {
    guard application.hasPendingWork else { break }
    let previous = try #require(application.indexingProgress)
    let update = application.performPendingWork()
    if let current = application.indexingProgress {
      #expect(current.indexedBytes >= previous.indexedBytes)
      #expect(current.indexedBytes - previous.indexedBytes <= PagedFileDocument.Indexer.maximumBytesPerBatch)
    }
    if update == .redraw {
      _ = application.render(in: size)
      try surface.render(size: size) { application.paint(in: &$0) }
      frames += 1
    }
  }
  #expect(!application.hasPendingWork)
  let elapsed = start.duration(to: clock.now)
  let layout = DocumentViewerLayout(size: size, byteCount: progress.totalBytes, showInspector: true)
  let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
  defer { try? handle.close() }
  var copy = CopyBuffer()
  for key in [InputKey.home, .end] {
    _ = application.event(.key(key, modifiers: []), copyBuffer: &copy)
    _ = application.render(in: size)
    try surface.render(size: size) { application.paint(in: &$0) }
    let count = min(progress.totalBytes, layout.text.width * layout.text.height)
    let offset = key == .home ? 0 : progress.totalBytes - count
    try handle.seek(toOffset: UInt64(offset))
    let reference = try handle.read(upToCount: count) ?? Data()
    for (index, byte) in reference.enumerated() {
      let scalar = (0x20...0x7e).contains(byte) ? Unicode.Scalar(byte) : "."
      #expect(
        surface.cell(
          x: layout.text.x + index % layout.text.width,
          y: layout.text.y + index / layout.text.width)?.glyph.scalar == scalar)
    }
  }
  print("indexing-ui-profile first_frame=\(firstFrame) ready=\(elapsed) frames=\(frames)")
}

/// Opt-in allocator instrumentation. A loaded malloc interposer must export the
/// three functions below and count only the synchronous caller's thread. Hooks
/// stay outside production targets. Calibration checks Swift allocation too.
@Test func fileViewerAllocationProfile() throws {
  guard ProcessInfo.processInfo.environment["SLATE_DOCUMENT_ALLOCATION_PROBE"] == "1" else { return }
  let library = try #require(dlopen(nil, RTLD_NOW))
  defer { dlclose(library) }
  let begin = unsafeBitCast(try #require(dlsym(library, "slate_probe_begin")), to: (@convention(c) () -> Void).self)
  let end = unsafeBitCast(try #require(dlsym(library, "slate_probe_end")), to: (@convention(c) () -> UInt64).self)
  let consume = unsafeBitCast(
    try #require(dlsym(library, "slate_probe_consume")),
    to: (@convention(c) (UnsafePointer<UInt8>?, Int) -> Void).self)
  begin()
  let calibration = [UInt8](repeating: 0x61, count: 8_192)
  calibration.withUnsafeBufferPointer { consume($0.baseAddress, $0.count) }
  let calibrationCount = end()
  #expect(calibrationCount > 0)

  let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slate-alloc-" + UUID().uuidString)
  // Include all byte values so maximum-size navigation, copying, and failure
  // redraws cover the binary reader as well as cache exhaustion.
  try Data((0..<65_536).map { UInt8($0 % 256) }).write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  let viewer = try DocumentFileViewer(url.path, configuration: .init(pageBytes: 64, cachePages: 1, maximumPages: 1_024))
  let size = TerminalSize(columns: 160, rows: 60)
  var surface = try Surface(maximumSize: size)
  // Warm every path before measuring maximum-size frames and repeated eviction.
  for step in 0..<64 {
    _ = viewer.handle(step % 2 == 0 ? .home : .end, modifiers: [])
    viewer.prepare(in: size)
    try surface.render(size: size) { viewer.paint(in: &$0) }
  }
  begin()
  for step in 0..<256 {
    _ = viewer.handle(step % 2 == 0 ? .home : .end, modifiers: [])
    if step % 8 == 0 { _ = viewer.handle(.character("C"), modifiers: []) }
    viewer.prepare(in: size)
    try surface.render(size: size) { viewer.paint(in: &$0) }
  }
  let steadyCount = end()
  #expect(steadyCount == 0)

  // Drag while a one-slot cache repeatedly evicts pages. Mouse handling itself
  // only changes scalar position; preparation/painting must also remain bounded.
  _ = viewer.handle(.home, modifiers: [])
  viewer.prepare(in: size)
  let dragLayout = DocumentViewerLayout(size: size, byteCount: 65_536, showInspector: true)
  let dragColumn = try #require(dragLayout.scrollbarColumn)
  _ = viewer.mouse(.init(action: .press, button: .left, column: dragColumn, row: dragLayout.text.y))
  _ = viewer.mouse(.init(action: .move, button: .left, column: 0, row: dragLayout.text.bottom - 1))
  viewer.prepare(in: size)
  try surface.render(size: size) { viewer.paint(in: &$0) }
  begin()
  for step in 0..<256 {
    let row = step % 2 == 0 ? dragLayout.text.y : dragLayout.text.bottom - 1
    _ = viewer.mouse(.init(action: .move, button: .left, column: 0, row: row))
    viewer.prepare(in: size)
    try surface.render(size: size) { viewer.paint(in: &$0) }
  }
  let dragCount = end()
  #expect(dragCount == 0)
  _ = viewer.mouse(.init(action: .release, button: .left, column: 0, row: dragLayout.text.bottom - 1))

  _ = viewer.handle(.home, modifiers: [])
  viewer.prepare(in: size)
  var selectionCopy = CopyBuffer()
  // Use the same call sites for warm-up and measurement, including copying
  // into the host buffer and consuming it without external clipboard writes.
  for step in 0..<320 {
    if step == 64 { begin() }
    _ = viewer.mouse(.init(action: .press, button: .left, column: dragLayout.text.x, row: dragLayout.text.y))
    _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: dragLayout.text.bottom - 1))
    _ = viewer.mouse(.init(action: .release, button: .left, column: 65_534, row: dragLayout.text.bottom - 1))
    viewer.prepare(in: size)
    _ = viewer.copySelection(to: &selectionCopy)
    selectionCopy.flush { _ in }
    try surface.render(size: size) { viewer.paint(in: &$0) }
  }
  let selectionCount = end()
  #expect(selectionCount == 0)

  // Repeated edge ticks preserve a range outside the prepared viewport. Warm
  // and measure the same copy path, including cache misses in the one-slot cache.
  for step in 0..<320 {
    if step == 64 { begin() }
    _ = viewer.handle(.home, modifiers: [])
    viewer.prepare(in: size)
    _ = viewer.mouse(.init(action: .press, button: .left, column: dragLayout.text.x, row: dragLayout.text.y))
    _ = viewer.mouse(.init(action: .move, button: .left, column: 65_534, row: 65_534))
    _ = viewer.performPendingWork(at: ContinuousClock().now.advanced(by: .seconds(1)))
    viewer.prepare(in: size)
    _ = viewer.copySelection(to: &selectionCopy)
    selectionCopy.flush { _ in }
    try surface.render(size: size) { viewer.paint(in: &$0) }
  }
  let edgeCount = end()
  #expect(edgeCount == 0)

  // A larger explicit request may grow CopyBuffer; subsequent copies of that
  // size or smaller must reuse the allocation, including after delivery.
  let largeText = String(repeating: "x", count: 131_073)
  begin()
  selectionCopy.copy(largeText.utf8Span)
  let copyGrowthCount = end()
  #expect(copyGrowthCount > 0)
  selectionCopy.flush { _ in }
  begin()
  for _ in 0..<256 {
    selectionCopy.copy("small".utf8Span)
    selectionCopy.copy(largeText.utf8Span)
    selectionCopy.flush { _ in }
  }
  let copyReuseCount = end()
  #expect(copyReuseCount == 0)

  let writer = try FileHandle(forWritingTo: url)
  try writer.truncate(atOffset: 1)
  try writer.close()
  viewer.prepare(in: size)
  try surface.render(size: size) { viewer.paint(in: &$0) }
  begin()
  for _ in 0..<256 {
    viewer.prepare(in: size)
    try surface.render(size: size) { viewer.paint(in: &$0) }
  }
  let failureCount = end()
  #expect(failureCount == 0)

  // The index itself may allocate bounded rope nodes during initialization;
  // progress painting must reuse the already-allocated UI storage.
  let openingURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "slate-progress-" + UUID().uuidString)
  try Data(repeating: 0x61, count: 65_536).write(to: openingURL)
  defer { try? FileManager.default.removeItem(at: openingURL) }
  let opening = try DocumentFileOpening(
    openingURL.path, configuration: .init(pageBytes: 64, cachePages: 1, maximumPages: 1_024))
  try opening.advance()
  try surface.render(size: size) { opening.paint(in: &$0) }
  begin()
  for _ in 0..<256 { try surface.render(size: size) { opening.paint(in: &$0) } }
  let progressCount = end()
  #expect(progressCount == 0)
  print(
    "allocation-profile calibration=\(calibrationCount) maximum_frames=256 allocations=\(steadyCount) drag_frames=256 allocations=\(dragCount) selection_copy_frames=256 allocations=\(selectionCount) edge_scroll_copy_frames=256 allocations=\(edgeCount) copy_growth_allocations=\(copyGrowthCount) copy_reuse_allocations=\(copyReuseCount) failed_frames=256 allocations=\(failureCount) progress_frames=256 allocations=\(progressCount)"
  )
}

/// Unicode frames exercise native segmentation, maximum grids, one-slot cache
/// eviction, cooperative seeks, owned glyph copies, and text-input painting.
@Test func unicodeAllocationProfile() throws {
  guard ProcessInfo.processInfo.environment["SLATE_DOCUMENT_ALLOCATION_PROBE"] == "1" else { return }
  let library = try #require(dlopen(nil, RTLD_NOW))
  defer { dlclose(library) }
  let begin = unsafeBitCast(try #require(dlsym(library, "slate_probe_begin")), to: (@convention(c) () -> Void).self)
  let end = unsafeBitCast(try #require(dlsym(library, "slate_probe_end")), to: (@convention(c) () -> UInt64).self)
  let mixed = "é漢e\u{301}👩🏽‍💻🇺🇸1️⃣Z"
  let fileText = String(repeating: mixed, count: 2_048)
  let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "slate-unicode-alloc-" + UUID().uuidString)
  try Data(fileText.utf8).write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  let viewer = try DocumentFileViewer(
    url.path, configuration: .init(pageBytes: 256, cachePages: 1, maximumPages: 1_024))
  let size = TerminalSize(columns: 160, rows: 60)
  var surface = try Surface(maximumSize: size)
  let input = try TextInput(mixed)
  let oversized = "e" + String(repeating: "\u{301}", count: 80)
  let budget = viewer.storageBudgetBytes + surface.storageBudgetBytes
  for step in 0..<320 {
    if step == 64 { begin() }
    _ = viewer.handle(step.isMultiple(of: 2) ? .home : .end, modifiers: [])
    viewer.prepare(in: size)
    try finishUnicodePreparation(viewer)
    try surface.render(size: size) {
      Column {
        Text(mixed)
        InputBox(input)
      }
    } paint: { frame in
      viewer.paint(in: &frame)
      frame.text(oversized, in: Rect(x: 1, y: 1, width: 12, height: 1))
    }
  }
  let count = end()
  #expect(count == 0)
  #expect(viewer.notice.isEmpty && viewer.visibleRange.upperBound == fileText.utf8.count)
  #expect(viewer.storageBudgetBytes + surface.storageBudgetBytes == budget)
  print("unicode-allocation-profile frames=256 allocations=\(count) working_storage_bytes=\(budget)")
  let layout = DocumentViewerLayout(size: size, byteCount: fileText.utf8.count, showInspector: true)
  for step in 0..<320 {
    if step == 64 { begin() }
    if step.isMultiple(of: 64) {
      _ = viewer.handle(.end, modifiers: [])
    } else {
      _ = viewer.mouse(.init(action: .scrollUp, button: .none, column: layout.text.x, row: layout.text.y))
    }
    viewer.prepare(in: size)
    try finishUnicodePreparation(viewer)
    try surface.render(size: size) { viewer.paint(in: &$0) }
  }
  let reverseCount = end()
  #expect(reverseCount == 0)
  #expect(viewer.storageBudgetBytes + surface.storageBudgetBytes == budget)
  print("unicode-reverse-allocation-profile frames=256 allocations=\(reverseCount)")
  let largeCluster = "a" + String(repeating: "\u{301}", count: 31)
  let maximumText = String(repeating: largeCluster, count: 9_600)
  let maximumURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "slate-unicode-max-" + UUID().uuidString)
  try Data(maximumText.utf8).write(to: maximumURL)
  defer { try? FileManager.default.removeItem(at: maximumURL) }
  var source = try PagedFileDocument.open(
    maximumURL.path, configuration: .init(pageBytes: 4_096, cachePages: 1, maximumPages: 256))
  var viewport = try FileByteViewport()
  var copy = CopyBuffer()
  for step in 0..<6 {
    if step == 2 { begin() }
    try viewport.prepare(from: &source, firstByte: 0, size: viewport.maximumSize)
    viewport.copy(viewport.visibleRange, to: &copy)
    copy.flush { _ in }
  }
  let maximumCount = end()
  #expect(maximumCount == 0 && viewport.visibleRange.count == maximumText.utf8.count)
  print(
    "unicode-maximum-allocation-profile cells=9600 source_bytes=\(maximumText.utf8.count) allocations=\(maximumCount)")
}
