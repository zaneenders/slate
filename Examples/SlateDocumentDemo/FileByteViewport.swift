import BasicContainers
import Slate

/// Two fixed grids of glyphs, byte ranges, and row offsets, plus two raw-byte
/// grids (64 bytes per possible cell). At 160x60 the array payload is 2,919,376
/// bytes; inline state is included by storageBudgetBytes. No capacity grows.
/// Unicode preparation runs in <=64 KiB / 16,384 scalar batches, with a 4 ms
/// deadline checked every 64 scalars. A page load/syscall may exceed it. Failed
/// or cancelled work preserves the previous snapshot. ASCII keeps the previous
/// <=9,600-byte path. Painting/copying do no I/O. Runtime warm-up and explicit
/// host copy-buffer growth are outside the steady-state allocation guarantee.
/// A 128-entry history stores distinct row starts and their owned Unicode state;
/// two inline 61-entry checkpoint grids follow the published/scratch row grids.
/// At capacity the oldest distinct row is replaced. Replay refills up to 61
/// preceding rows. Each publication does at most 182 * 128 history comparisons.
/// A miss estimates its lookback from observed row byte counts, doubling at most
/// eight times up to 60 * columns * 64 bytes if preceding rows need more space.
struct FileByteViewport: ~Copyable, ~Sendable {
  let maximumSize: TerminalSize
  private var bytes: RigidArray<UInt8>
  private var scratch: RigidArray<UInt8>
  private var glyphs: RigidArray<Glyph>
  private var scratchGlyphs: RigidArray<Glyph>
  private var ranges: RigidArray<Range<Int>>
  private var scratchRanges: RigidArray<Range<Int>>
  private var rows: RigidArray<Int>
  private var scratchRows: RigidArray<Int>
  private var preparation: FileUnicodePreparation?
  private var sourceIdentity: DocumentFileIdentity?
  private var publishedIdentity: DocumentFileIdentity?
  private var rowCheckpoints = InlineArray<61, FileUnicodeCheckpoint>(repeating: .init())
  private var scratchRowCheckpoints = InlineArray<61, FileUnicodeCheckpoint>(repeating: .init())
  private var history = InlineArray<128, FileRowAnchor>(repeating: .init())
  private var historyCursor = 0
  private var asciiPrepared = false
  private(set) var size = TerminalSize(columns: 0, rows: 0)
  private(set) var visibleRange = 0..<0

  init(maximumSize: TerminalSize = .init(columns: 160, rows: 60)) throws(FileDocumentError) {
    guard (1...160).contains(maximumSize.columns), (1...60).contains(maximumSize.rows) else {
      throw .invalidConfiguration
    }
    self.maximumSize = maximumSize
    let count = maximumSize.columns * maximumSize.rows
    bytes = RigidArray(repeating: 0, count: count * Glyph.maximumUTF8Bytes)
    scratch = RigidArray(repeating: 0, count: count * Glyph.maximumUTF8Bytes)
    glyphs = RigidArray(repeating: .space, count: count)
    scratchGlyphs = RigidArray(repeating: .space, count: count)
    ranges = RigidArray(repeating: 0..<0, count: count)
    scratchRanges = RigidArray(repeating: 0..<0, count: count)
    rows = RigidArray(repeating: 0, count: maximumSize.rows + 1)
    scratchRows = RigidArray(repeating: 0, count: maximumSize.rows + 1)
  }

  var storageBudgetBytes: Int {
    bytes.count + scratch.count + (glyphs.count + scratchGlyphs.count) * MemoryLayout<Glyph>.stride
      + (ranges.count + scratchRanges.count) * MemoryLayout<Range<Int>>.stride
      + (rows.count + scratchRows.count) * MemoryLayout<Int>.stride + MemoryLayout<Self>.stride
  }
  var hasPendingWork: Bool { preparation != nil }
  mutating func cancelPreparation() { preparation = nil }
  borrowing func byte(at index: Int) -> UInt8? { (0..<visibleRange.count).contains(index) ? bytes[index] : nil }

  borrowing func rowRange(at row: Int) -> Range<Int>? {
    guard row >= 0 && row < size.rows && rows[row] < rows[row + 1] else { return nil }
    return rows[row]..<rows[row + 1]
  }

  borrowing func byteRange(column: Int, row: Int, clamp: Bool) -> Range<Int>? {
    guard size.columns > 0 && size.rows > 0 && !visibleRange.isEmpty else { return nil }
    if !clamp && (column < 0 || column >= size.columns || row < 0 || row >= size.rows) { return nil }
    let x = min(size.columns - 1, max(0, column))
    let y = min(size.rows - 1, max(0, row))
    var index = y * size.columns + x
    if asciiPrepared {
      if index >= visibleRange.count { return clamp ? visibleRange.upperBound - 1..<visibleRange.upperBound : nil }
      return visibleRange.lowerBound + index..<visibleRange.lowerBound + index + 1
    }
    if !ranges[index].isEmpty { return ranges[index] }
    guard clamp else { return nil }
    while index > 0 {
      index -= 1
      if !ranges[index].isEmpty { return ranges[index] }
    }
    return nil
  }

  /// Cache exhaustion triggers bounded replay during preparation, never I/O in
  /// mouse/key handlers. Reverse requests coalesce to at most 60 rows per frame.
  borrowing func offset(scrollingRows delta: Int, from firstByte: Int) -> Int? {
    if delta >= 0 {
      for row in 0..<size.rows where rows[row] == firstByte {
        let target = min(size.rows, row + delta)
        return rows[target] > firstByte ? rows[target] : firstByte
      }
      return nil
    }
    var result = firstByte
    for _ in 0..<min(60, -delta) {
      if result == 0 { break }
      var previous: Int?
      for age in 0..<history.count {
        let index = (historyCursor + history.count - 1 - age) % history.count
        if history[index].offset == result {
          previous = history[index].previous
          break
        }
      }
      guard let previous, previous < result else { return nil }
      result = previous
    }
    return result
  }

  /// Copy cancels unpublished preparation before reusing its scratch. Valid
  /// Unicode remains original; malformed bytes and controls become dots.
  mutating func copy(_ range: Range<Int>, to copyBuffer: inout CopyBuffer) {
    precondition(range.lowerBound >= visibleRange.lowerBound && range.upperBound <= visibleRange.upperBound)
    preparation = nil
    let first = range.lowerBound - visibleRange.lowerBound
    for index in 0..<range.count { scratch[index] = bytes[first + index] }
    do {
      var storage = scratch.mutableSpan
      sanitizeFileCopy(storage._mutatingExtracting(first: range.count))
    }
    copyBuffer.copy(unsafe UTF8Span(unchecked: scratch.span.extracting(first: range.count)))
  }

  /// Blocking convenience for tests/non-UI callers. The viewer drives batches
  /// separately and publishes only complete snapshots between UI turns.
  mutating func prepare(
    from source: inout PagedFileDocument, firstByte: Int, size: TerminalSize
  ) throws(FileDocumentError) {
    try begin(from: &source, firstByte: firstByte, size: size)
    while hasPendingWork { _ = try advance(from: &source) }
  }

  mutating func begin(
    from source: inout PagedFileDocument, firstByte: Int, size: TerminalSize, backwardRows: Int = 0
  ) throws(FileDocumentError) {
    guard size.columns <= maximumSize.columns, size.rows <= maximumSize.rows,
      (0...source.byteCount).contains(firstByte), (0...60).contains(backwardRows)
    else { throw .invalidRange }
    try source.verifyUnchanged()
    preparation = nil
    if sourceIdentity != source.snapshotIdentity || self.size.columns != size.columns {
      for index in 0..<history.count { history[index] = .init() }
      historyCursor = 0
      sourceIdentity = source.snapshotIdentity
    }
    if size.columns == 0 || size.rows == 0 {
      for row in 0...size.rows { scratchRows[row] = firstByte }
      commit(firstByte: firstByte, byteCount: 0, size: size)
      return
    }
    if source.isASCII {
      let first =
        firstByte == source.byteCount
        ? max(0, source.byteCount - size.columns * size.rows)
        : max(0, firstByte - backwardRows * size.columns)
      try prepareASCII(from: &source, firstByte: first, size: size)
      return
    }
    for index in 0..<size.columns * size.rows {
      scratchGlyphs[index] = .space
      scratchRanges[index] = 0..<0
    }
    for row in 0...size.rows { scratchRows[row] = firstByte }
    let locating = (firstByte == source.byteCount || backwardRows > 0) && firstByte > 0
    var bytesPerRow = size.columns
    if self.size.columns == size.columns && publishedIdentity == sourceIdentity {
      for row in 0..<self.size.rows { bytesPerRow = max(bytesPerRow, rows[row + 1] - rows[row]) }
    }
    let lookback = min(size.columns * 60 * Glyph.maximumUTF8Bytes, max(4_096, bytesPerRow * 61))
    let start = locating ? max(0, firstByte - lookback) : firstByte
    let checkpoint =
      !locating
      ? cachedCheckpoint(at: firstByte) ?? source.unicodeCheckpoint(before: start)
      : source.unicodeCheckpoint(before: start)
    preparation = FileUnicodePreparation(
      checkpoint: checkpoint, target: firstByte, size: size,
      locating: locating, backwardRows: firstByte == source.byteCount ? size.rows : backwardRows,
      lookbackBytes: lookback)
  }

  /// Returns true when a complete snapshot was published. No source/span
  /// borrow survives the return to the event loop.
  mutating func advance(
    from source: inout PagedFileDocument, maximumScalars: Int = 16_384
  ) throws(FileDocumentError) -> Bool {
    guard (1...16_384).contains(maximumScalars) else { throw .invalidConfiguration }
    guard var state = preparation.take() else { return false }
    try source.verifyUnchanged()
    let deadline = ContinuousClock().now.advanced(by: .milliseconds(4))
    var scannedBytes = 0
    var scalars = 0
    while scannedBytes < 65_536 && scalars < maximumScalars {
      if let token = try state.cursor.next(from: &source) {
        scannedBytes += token.range.count
        scalars += 1
        let initial = state.clusters.initialState
        if let complete = state.clusters.append(
          token.scalar, at: token.range.lowerBound, sourceBytes: token.range.count)
        {
          let checkpoint = FileUnicodeCheckpoint(
            offset: complete.byteRange.lowerBound, recognizer: initial.recognizer, fragmented: initial.fragmented)
          let action = consume(complete, checkpoint: checkpoint, state: &state, source: &source)
          state.rawCount = 0
          if action == .complete {
            try source.verifyUnchanged()
            rememberReplayRows(state: &state)
            commit(firstByte: state.firstVisible ?? state.target, byteCount: state.byteCount, size: state.size)
            return true
          }
          if action == .restarted { continue }
        }
        precondition(state.rawCount + token.range.count <= Glyph.maximumUTF8Bytes)
        for index in 0..<token.range.count { state.raw[state.rawCount + index] = token.raw[index] }
        state.rawCount += token.range.count
      } else {
        let initial = state.clusters.initialState
        if let complete = state.clusters.take() {
          let checkpoint = FileUnicodeCheckpoint(
            offset: complete.byteRange.lowerBound, recognizer: initial.recognizer, fragmented: initial.fragmented)
          let action = consume(complete, checkpoint: checkpoint, state: &state, source: &source)
          state.rawCount = 0
          if action == .restarted { continue }
        }
        if state.locating {
          restartDisplay(state: &state, source: &source)
          continue
        }
        try source.verifyUnchanged()
        rememberReplayRows(state: &state)
        commit(firstByte: state.firstVisible ?? state.target, byteCount: state.byteCount, size: state.size)
        return true
      }
      if scalars.isMultiple(of: 64) && ContinuousClock().now >= deadline { break }
    }
    try source.verifyUnchanged()
    preparation = consume state
    return false
  }

  private enum ConsumeAction { case more, restarted, complete }

  private mutating func consume(
    _ cluster: UnicodeGrapheme, checkpoint: FileUnicodeCheckpoint,
    state: inout FileUnicodePreparation, source: inout PagedFileDocument
  ) -> ConsumeAction {
    assert(cluster.byteRange.count == state.rawCount)
    if state.locating {
      if cluster.byteRange.lowerBound >= state.target {
        restartDisplay(state: &state, source: &source)
        return .restarted
      }
      let width = min(state.size.columns, cluster.glyph.columnWidth)
      if state.column + width > state.size.columns { state.column = 0 }
      if state.column == 0 {
        state.anchors[state.anchorCount % state.anchors.count] = checkpoint
        state.anchorCount += 1
      }
      state.column += width
      if state.column == state.size.columns { state.column = 0 }
      return .more
    }
    guard cluster.byteRange.upperBound > state.target else { return .more }
    var glyph = cluster.firstScalar == "\0" ? Glyph(".")! : cluster.glyph
    if glyph.columnWidth > state.size.columns { glyph = .replacement }
    if state.column + glyph.columnWidth > state.size.columns {
      state.row += 1
      state.column = 0
    }
    guard state.row < state.size.rows else { return .complete }
    if state.firstVisible == nil { state.firstVisible = cluster.byteRange.lowerBound }
    if state.column == 0 {
      scratchRows[state.row] = cluster.byteRange.lowerBound
      scratchRowCheckpoints[state.row] = checkpoint
    }
    let index = state.row * state.size.columns + state.column
    scratchGlyphs[index] = glyph
    scratchRanges[index] = cluster.byteRange
    if glyph.columnWidth == 2 {
      scratchGlyphs[index + 1] = .continuation
      scratchRanges[index + 1] = cluster.byteRange
    }
    precondition(state.byteCount + state.rawCount <= scratch.count)
    for byte in 0..<state.rawCount { scratch[state.byteCount + byte] = state.raw[byte] }
    state.byteCount += state.rawCount
    scratchRows[state.row + 1] = cluster.byteRange.upperBound
    state.column += glyph.columnWidth
    if state.column == state.size.columns {
      state.column = 0
      state.row += 1
    }
    return .more
  }

  private func restartDisplay(state: inout FileUnicodePreparation, source: inout PagedFileDocument) {
    let maximumLookback = state.size.columns * 60 * Glyph.maximumUTF8Bytes
    if state.anchorCount < max(1, state.backwardRows) && state.replayStart > 0
      && state.lookbackBytes < maximumLookback && state.replayAttempts < 8
    {
      state.lookbackBytes = min(maximumLookback, state.lookbackBytes * 2)
      state.replayAttempts += 1
      let checkpoint = source.unicodeCheckpoint(before: max(0, state.target - state.lookbackBytes))
      state.cursor = FileUnicodeCursor(offset: checkpoint.offset)
      state.clusters = UnicodeGraphemeBuffer(recognizer: checkpoint.recognizer, fragmented: checkpoint.fragmented)
      state.replayStart = checkpoint.offset
      state.anchorCount = 0
      state.column = 0
      state.rawCount = 0
      return
    }
    let available = min(state.anchorCount, state.anchors.count)
    let back = min(available, max(1, state.backwardRows))
    let ordinal = state.anchorCount - back
    let checkpoint = available == 0 ? FileUnicodeCheckpoint() : state.anchors[ordinal % state.anchors.count]
    state.cursor = FileUnicodeCursor(offset: checkpoint.offset)
    state.clusters = UnicodeGraphemeBuffer(recognizer: checkpoint.recognizer, fragmented: checkpoint.fragmented)
    state.target = checkpoint.offset
    state.locating = false
    state.column = 0
    state.row = 0
    state.rawCount = 0
  }

  private mutating func prepareASCII(
    from source: inout PagedFileDocument, firstByte: Int, size: TerminalSize
  ) throws(FileDocumentError) {
    let count = min(size.columns * size.rows, source.byteCount - firstByte)
    var copied = 0
    while copied < count {
      var storage = scratch.mutableSpan
      let amount = try source.readBytes(from: firstByte + copied, into: storage._mutatingExtracting(copied..<count))
      guard amount > 0 && amount <= count - copied else { throw .fileChanged }
      copied += amount
    }
    for row in 0...size.rows { scratchRows[row] = firstByte + min(count, row * size.columns) }
    try source.verifyUnchanged()
    commit(firstByte: firstByte, byteCount: count, size: size, ascii: true)
  }

  private mutating func commit(firstByte: Int, byteCount: Int, size: TerminalSize, ascii: Bool = false) {
    if self.size.columns == size.columns && publishedIdentity == sourceIdentity {
      rememberRows()
    }
    swap(&bytes, &scratch)
    swap(&glyphs, &scratchGlyphs)
    swap(&ranges, &scratchRanges)
    swap(&rows, &scratchRows)
    swap(&rowCheckpoints, &scratchRowCheckpoints)
    visibleRange = firstByte..<firstByte + byteCount
    asciiPrepared = ascii
    publishedIdentity = sourceIdentity
    self.size = size
    for row in 0...size.rows where rows[row] < firstByte || rows[row] > visibleRange.upperBound {
      rows[row] = visibleRange.upperBound
    }
    if size.rows > 0 {
      for row in 1...size.rows where rows[row] < rows[row - 1] { rows[row] = rows[row - 1] }
    }
    rememberRows()
  }

  private mutating func rememberRows() {
    guard !asciiPrepared, size.rows > 0 else { return }
    for row in 0..<size.rows where rows[row] < rows[row + 1] {
      remember(rowCheckpoints[row], previous: row > 0 ? rows[row - 1] : -1)
    }
  }

  private borrowing func cachedCheckpoint(at offset: Int) -> FileUnicodeCheckpoint? {
    for age in 0..<history.count {
      let index = (historyCursor + history.count - 1 - age) % history.count
      if history[index].offset == offset { return history[index].checkpoint }
    }
    return nil
  }

  private mutating func remember(_ checkpoint: FileUnicodeCheckpoint, previous: Int) {
    for index in 0..<history.count where history[index].offset == checkpoint.offset {
      if previous >= 0 { history[index].previous = previous }
      return
    }
    history[historyCursor] = .init(offset: checkpoint.offset, previous: previous, checkpoint: checkpoint)
    historyCursor = (historyCursor + 1) % history.count
  }

  private mutating func rememberReplayRows(state: inout FileUnicodePreparation) {
    let count = min(state.anchorCount, state.anchors.count)
    let start = state.anchorCount - count
    var previous = -1
    for ordinal in start..<state.anchorCount {
      let checkpoint = state.anchors[ordinal % state.anchors.count]
      remember(checkpoint, previous: previous)
      previous = checkpoint.offset
    }
  }

  borrowing func paint(
    in area: Rect, frame: inout Frame, pageBytes: Int,
    previousRange: Range<Int>, style: Style, revealedStyle: Style, boundaryStyle: Style,
    selection: Range<Int>? = nil, selectionStyle: Style = Style(foreground: .white, background: .blue),
    match: Range<Int>? = nil, matchStyle: Style = Style(foreground: .black, background: .yellow)
  ) {
    precondition(pageBytes > 0)
    let clipped = area.intersection(frame.area)
    let columns = min(size.columns, max(0, clipped.right - area.x))
    let rows = min(size.rows, max(0, clipped.bottom - area.y))
    guard columns > 0 && rows > 0 else { return }
    for row in 0..<rows {
      for column in 0..<columns {
        let index = row * size.columns + column
        let range =
          asciiPrepared
          ? (index < visibleRange.count ? visibleRange.lowerBound + index..<visibleRange.lowerBound + index + 1 : 0..<0)
          : ranges[index]
        guard !range.isEmpty else { continue }
        var cellStyle = previousRange.isEmpty || previousRange.overlaps(range) ? style : revealedStyle
        if range.lowerBound / pageBytes != (range.upperBound - 1) / pageBytes || range.lowerBound % pageBytes == 0 {
          cellStyle.foreground = boundaryStyle.foreground
          cellStyle.underlined = true
          cellStyle.bold = true
        }
        if match?.overlaps(range) == true {
          cellStyle.foreground = matchStyle.foreground
          cellStyle.background = matchStyle.background
        }
        if selection?.overlaps(range) == true {
          cellStyle.foreground = selectionStyle.foreground
          cellStyle.background = selectionStyle.background
        }
        let value = asciiPrepared && index < visibleRange.count ? bytes[index] : 0
        let glyph =
          asciiPrepared
          ? ((0x20...0x7e).contains(value) ? Glyph(Unicode.Scalar(value))! : Glyph(".")!)
          : glyphs[index]
        frame[area.x + column, area.y + row] =
          Cell(glyph.columnWidth == 2 && column + 1 == columns ? .space : glyph, style: cellStyle)
      }
    }
  }
}

// Module scope avoids the pinned compiler's private noncopyable metadata bug.
struct FileUnicodePreparation: ~Copyable {
  var cursor: FileUnicodeCursor
  var clusters: UnicodeGraphemeBuffer
  var target: Int
  let size: TerminalSize
  var locating: Bool
  let backwardRows: Int
  var anchors = InlineArray<61, FileUnicodeCheckpoint>(repeating: .init())
  var anchorCount = 0
  var lookbackBytes: Int
  var replayStart: Int
  var replayAttempts = 0
  var raw = InlineArray<64, UInt8>(repeating: 0)
  var rawCount = 0
  var column = 0
  var row = 0
  var firstVisible: Int?
  var byteCount = 0

  init(
    checkpoint: FileUnicodeCheckpoint, target: Int, size: TerminalSize,
    locating: Bool, backwardRows: Int, lookbackBytes: Int
  ) {
    cursor = FileUnicodeCursor(offset: checkpoint.offset)
    clusters = UnicodeGraphemeBuffer(recognizer: checkpoint.recognizer, fragmented: checkpoint.fragmented)
    self.target = target
    self.size = size
    self.locating = locating
    self.backwardRows = backwardRows
    self.lookbackBytes = lookbackBytes
    replayStart = checkpoint.offset
  }
}

struct FileRowAnchor {
  var offset = -1
  var previous = -1
  var checkpoint = FileUnicodeCheckpoint()
}

/// Same-byte-count copy normalization: <=4 examined bytes per source byte.
func sanitizeFileCopy(_ bytes: consuming MutableSpan<UInt8>) {
  var bytes = consume bytes
  var start = 0
  while start < bytes.count {
    var decoder = IncrementalUTF8Decoder()
    var validLength = 0
    for index in start..<min(bytes.count, start + 4) {
      switch decoder.append(bytes[index]) {
      case .pending: continue
      case .scalar(let scalar):
        if Glyph.scalarColumns(scalar) != nil { validLength = index - start + 1 }
      case .invalid: break
      }
      break
    }
    if validLength > 0 {
      start += validLength
    } else {
      bytes[start] = 0x2e
      start += 1
    }
  }
}
