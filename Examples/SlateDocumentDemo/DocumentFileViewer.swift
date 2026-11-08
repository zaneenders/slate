import BasicContainers
import Slate

/// Navigation and diagnostics for the reader. Storage is one fixed byte viewport,
/// 64 cache IDs/flags, and startup-owned labels. Paint never reads the file,
/// formats Strings, or grows collections. No event history is accumulated.
/// Drag capture retains two row offsets; mouse handlers do no I/O. Input batches
/// coalesce position changes before the next bounded viewport preparation.
/// Selection paints inside the pane and extends across edge-scrolled views.
/// Explicit offscreen copies may grow scratch storage to the selected byte count
/// (at most the file size), then copy into the host buffer: two retained buffers
/// proportional to the largest copy. Reads use the bounded cache. In-view copies
/// reuse the viewport scratch grid. Mouse handlers never access disk or allocate.
/// An initial source failure may allocate a Swift error box. It is latched until
/// reopen, so subsequent help/resize/failure redraws never retry or allocate.
final class DocumentFileViewer: ~Sendable {
  private var source: PagedFileDocument
  private var search = DocumentSearch()
  private var viewport = try! FileByteViewport()
  private let displayName: String
  private var cachedPages = InlineArray<64, Int>(repeating: -1)
  private var freshSlots = InlineArray<64, Bool>(repeating: false)
  private var previousRange = 0..<0
  private var visibleBytes = 0
  private var rowBytes = 1
  private var reloadRequested = true
  private var showInspector = true
  private var preparationFailed = false
  private var preparedSize: TerminalSize?
  private var backwardRows = 0
  private struct ViewportRequest {
    let firstByte: Int
    let size: TerminalSize
    let statistics: FilePageStatistics
    let previousRange: Range<Int>
    let preserveSelection: Bool
  }
  private var viewportRequest: ViewportRequest?
  private struct ScrollbarDrag {
    let grabOffsetRows: Int
    var lastPointerRow: Int
  }
  private var textSelection: DocumentSelection?
  private var selectionCopied = false
  private var selectionCopyBytes = UniqueArray<UInt8>()
  private struct SelectionDrag {
    var column: Int
    var row: Int
    var scrollDeadline: ContinuousClock.Instant?
  }
  private enum MouseCapture {
    case idle
    case scrollbar(ScrollbarDrag)
    case selection(SelectionDrag)

    var isScrollbar: Bool {
      if case .scrollbar = self { return true }
      return false
    }
  }
  private var mouseCapture = MouseCapture.idle
  private var selectionScrollPending = false
  private(set) var firstByte = 0
  private(set) var lastPageLoads: UInt64 = 0
  private(set) var lastBytesRead: UInt64 = 0
  private(set) var lastEvictions: UInt64 = 0
  private(set) var lastCacheHits: UInt64 = 0
  private(set) var helpVisible = false
  private(set) var notice = ""

  var visibleRange: Range<Int> { viewport.visibleRange }
  var isPreparingViewport: Bool { viewport.hasPendingWork }
  var selectionRange: Range<Int>? { textSelection?.range }
  var statistics: FilePageStatistics { source.statistics }
  var searchMatch: Range<Int>? { search.match }
  var searchState: DocumentSearch.State { search.state }
  var searchVisible: Bool { search.isVisible }
  var searchFocused: Bool { search.isFocused }
  var storageBudgetBytes: Int {
    source.cacheStorageBudgetBytes + viewport.storageBudgetBytes + selectionCopyBytes.capacity + search.storagePayloadBytes
  }
  var hasPendingWork: Bool {
    if viewport.hasPendingWork || search.hasPendingWork { return true }
    guard case .selection(let drag) = mouseCapture,
      let deadline = drag.scrollDeadline, selectionScrollDirection(at: drag) != 0
    else { return false }
    return ContinuousClock().now >= deadline
  }

  private let helpLines = [
    "FILE BYTES -> DISK PAGES -> CACHE SLOTS -> VIEWPORT",
    "Up/Down / j k   Scroll one row of bytes",
    "PgUp/PgDn       Move one screen; Space pages down",
    "0 ... 9         Jump to 0% ... 90% of file bytes",
    "g / G           Beginning / end of file",
    "[ / ]           Previous / next disk-page boundary",
    "Mouse           Drag scrollbar / click track; wheel scrolls rows",
    "Drag text       Select file bytes; y / Ctrl-C copies; Escape clears",
    "Hold at edge    Scroll while selecting across file bytes",
    "/              Search literal UTF-8; type to find; Enter / n next",
    "Tab / Escape   Switch search focus / close and cancel search",
    "",
    "WATCH THE READER",
    "Gutter          Zero-based byte offset of each row",
    "Underlined byte Start of a disk page",
    "+ / # / .       Newly loaded / resident / uncached pages",
    ">               Row contains newly revealed bytes",
    "C               Clear Slate's cache (OS cache is unchanged)",
    "I               Toggle cache slots on wide terminals",
    "UTF-8 view: controls and malformed bytes show as dots",
    "? / Escape      Close help     Q / Ctrl-C: quit"
  ]

  convenience init(
    _ path: String, configuration: FileDocumentConfiguration = .init(),
    progress: ((Int, Int) -> Void)? = nil
  ) throws(FileDocumentError) {
    self.init(
      path, source: try PagedFileDocument.open(path, configuration: configuration, content: .bytes, progress: progress))
  }

  init(_ path: String, source: consuming PagedFileDocument) {
    self.source = consume source
    if let slash = path.lastIndex(of: "/") {
      displayName = String(path[path.index(after: slash)...])
    } else {
      displayName = path
    }
  }

  func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(let key, let modifiers):
      if !helpVisible && !preparationFailed,
        let update = search.handle(
          key, modifiers: modifiers, copyBuffer: &copyBuffer, firstByte: firstByte, byteCount: source.byteCount)
      {
        clearSelection()
        return update
      }
      let copy = key == .control(.c) || (modifiers == .control && key == .character("c"))
        || (modifiers.isEmpty && key == .character("y"))
      if copy && !helpVisible && selectionRange != nil { return copySelection(to: &copyBuffer) }
      return handle(key, modifiers: modifiers)
    case .mouse(let event):
      if search.isVisible && event.action == .press && event.button == .left {
        if let size = preparedSize, event.row >= size.rows {
          search.focus(from: firstByte)
          clearSelection()
          return .redraw
        }
        let wasFocused = search.isFocused
        search.blur()
        let update = mouse(event)
        return wasFocused && update == .none ? .redraw : update
      }
      return mouse(event)
    case .paste(let text): return search.paste(text, byteCount: source.byteCount)
    case .pasteRejected: return .none
    }
  }

  /// Blocks own the search strip; custom drawing owns only the rows above it.
  func render(in size: TerminalSize) -> some Block {
    prepare(in: documentSize(in: size))
    return Column {
      Row {}.frame(width: .fill, height: .fill)
      if search.isVisible {
        Row(gap: 1) {
          Text("/", style: ViewerPalette.accent)
          InputBox(search.input, focused: search.isFocused, placeholder: "Find literal UTF-8", style: ViewerPalette.body)
        }.frame(width: .fill, height: .fixed(1))
        Row { Text(search.statusMessage, style: ViewerPalette.muted) }
          .frame(width: .fill, height: .fixed(1))
      }
    }.frame(width: .fill, height: .fill, alignment: .topLeading)
  }

  private func documentSize(in size: TerminalSize) -> TerminalSize {
    TerminalSize(columns: size.columns, rows: max(0, size.rows - (search.isVisible ? 2 : 0)))
  }

  func handle(_ key: InputKey, modifiers: KeyModifiers) -> ScreenUpdate {
    let cancelledDrag = mouseCapture.isScrollbar
    mouseCapture = .idle
    selectionScrollPending = false
    if key == .control(.q) || key == .control(.c) { return .quit }
    if modifiers == .control && (key == .character("q") || key == .character("c")) { return .quit }
    if helpVisible {
      if key == .escape || key == .character("?") {
        helpVisible = false
        return .redraw
      }
      return key == .character("q") ? .quit : .none
    }
    if key == .escape {
      if textSelection != nil {
        clearSelection()
        return .redraw
      }
      return .quit
    }
    if preparationFailed && key != .character("q") && key != .character("?")
      && key != .character("i") && key != .character("I")
    {
      return .none
    }
    if modifiers == .control && key == .home {
      backwardRows = 0
      firstByte = 0
      return .redraw
    }
    if modifiers == .control && key == .end {
      backwardRows = 0
      firstByte = source.isASCII ? maximumFirstByte : source.byteCount
      return .redraw
    }
    guard modifiers.isEmpty else { return cancelledDrag ? .redraw : .none }
    switch key {
    case .character("q"): return .quit
    case .character("?"): helpVisible = true
    case .character("i"), .character("I"): showInspector.toggle()
    case .character("c"), .character("C"):
      source.discardCachedPages()
      for slot in 0..<source.configuration.cachePages { cachedPages[slot] = -1 }
      reloadRequested = true
    case .up, .character("k"): scroll(rows: -1)
    case .down, .character("j"): scroll(rows: 1)
    case .pageUp: scroll(rows: -max(1, viewport.size.rows))
    case .pageDown, .character(" "): scroll(rows: max(1, viewport.size.rows))
    case .home, .character("g"):
      firstByte = 0
      backwardRows = 0
    case .end, .character("G"):
      firstByte = source.isASCII ? maximumFirstByte : source.byteCount
      backwardRows = 0
    case .character("["):
      backwardRows = 0
      let page = firstByte / source.configuration.pageBytes
      firstByte =
        firstByte % source.configuration.pageBytes == 0
        ? max(0, page - 1) * source.configuration.pageBytes : page * source.configuration.pageBytes
    case .character("]"):
      backwardRows = 0
      firstByte = min(
        maximumFirstByte, (firstByte / source.configuration.pageBytes + 1) * source.configuration.pageBytes)
    case .character(let scalar) where (0x30...0x39).contains(scalar.value):
      backwardRows = 0
      // Configured files are at most 1 TiB; multiplication fits a 64-bit Int.
      firstByte = max(0, source.byteCount - 1) * Int(scalar.value - 0x30) / 10
    default: return cancelledDrag ? .redraw : .none
    }
    return .redraw
  }

  private var maximumFirstByte: Int { max(0, source.byteCount - max(1, visibleBytes)) }

  private func scroll(rows delta: Int) {
    if delta < 0 && viewport.hasPendingWork {
      // Trackpad bursts must let the current replay finish. Retain at most one
      // additional 60-row reverse request instead of restarting every UI turn.
      backwardRows = min(60, backwardRows - delta)
      return
    }
    if delta > 0 && backwardRows > 0 {
      backwardRows = max(0, backwardRows - delta)
      return
    }
    if source.isASCII {
      firstByte = min(maximumFirstByte, max(0, firstByte + delta * rowBytes))
    } else if delta > 0 && viewport.visibleRange.upperBound == source.byteCount {
      return
    } else if let offset = viewport.offset(scrollingRows: delta, from: firstByte) {
      firstByte = min(source.byteCount, offset)
    } else if delta < 0 {
      backwardRows = min(60, backwardRows - delta)
    } else {
      firstByte = min(source.byteCount, firstByte + max(1, visibleBytes) * delta / max(1, viewport.size.rows))
    }
  }

  func copySelection(to copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    guard !helpVisible, !preparationFailed, let range = selectionRange else { return .none }
    finishSelectionCapture()
    viewport.cancelPreparation()
    viewportRequest = nil
    backwardRows = 0
    firstByte = viewport.visibleRange.lowerBound
    if range.lowerBound >= viewport.visibleRange.lowerBound && range.upperBound <= viewport.visibleRange.upperBound {
      viewport.copy(range, to: &copyBuffer)
    } else {
      let before = source.statistics
      do throws(FileDocumentError) {
        try source.verifyUnchanged()
        // Copy requests are the only allocation path after initialization.
        // Keep initialized scratch at its high-water mark for later copies.
        if range.count > selectionCopyBytes.count {
          selectionCopyBytes.reserveCapacity(range.count)
          while selectionCopyBytes.count < range.count { selectionCopyBytes.append(0) }
        }
        var count = 0
        while count < range.count {
          var bytes = selectionCopyBytes.mutableSpan
          let copied = try source.readBytes(
            from: range.lowerBound + count, into: bytes._mutatingExtracting(count..<range.count))
          guard copied > 0 && copied <= range.count - count else { throw .fileChanged }
          count += copied
        }
        try source.verifyUnchanged()
      } catch {
        preparationFailed = true
        mouseCapture = .idle
        clearSelection()
        notice = Self.message(for: error)
        updateReadStatistics(since: before)
        return .redraw
      }
      do {
        var bytes = selectionCopyBytes.mutableSpan
        sanitizeFileCopy(bytes._mutatingExtracting(first: range.count))
      }
      copyBuffer.copy(unsafe UTF8Span(unchecked: selectionCopyBytes.span.extracting(first: range.count)))
      updateReadStatistics(since: before)
    }
    selectionCopied = true
    return .redraw
  }

  private func clearSelection() {
    textSelection = nil
    selectionCopied = false
    finishSelectionCapture()
    selectionScrollPending = false
  }

  private func finishSelectionCapture() {
    if case .selection = mouseCapture { mouseCapture = .idle }
  }

  private func finishScrollbarCapture() {
    if case .scrollbar = mouseCapture { mouseCapture = .idle }
  }

  private func selectionScrollDirection(at pointer: SelectionDrag) -> Int {
    guard textSelection?.hasMoved == true, let size = preparedSize,
      !helpVisible, !preparationFailed
    else { return 0 }
    let layout = DocumentViewerLayout(size: size, byteCount: source.byteCount, showInspector: showInspector)
    guard layout.text.height > 0 else { return 0 }
    if pointer.row <= layout.text.y && firstByte > 0 {
      return -1
    }
    if pointer.row >= layout.text.bottom - 1 && viewport.visibleRange.upperBound < source.byteCount {
      return 1
    }
    return 0
  }

  /// At most three rows per 50 ms tick and one viewport per frame. Returning
  /// false from hasPendingWork until due lets the runner sleep between ticks.
  func performPendingWork(at now: ContinuousClock.Instant = ContinuousClock().now) -> ScreenUpdate {
    if viewport.hasPendingWork { return advanceViewport() }
    if search.hasPendingWork {
      if let match = search.advance(from: &source) {
        clearSelection()
        firstByte = match.lowerBound
        backwardRows = 0
      }
      return search.hasPendingWork ? .none : .redraw
    }
    guard case .selection(var drag) = mouseCapture,
      let deadline = drag.scrollDeadline, now >= deadline
    else { return .none }
    let direction = selectionScrollDirection(at: drag)
    guard direction != 0, preparedSize != nil else {
      drag.scrollDeadline = nil
      mouseCapture = .selection(drag)
      return .none
    }
    scroll(rows: direction * 3)
    selectionCopied = false
    selectionScrollPending = true
    drag.scrollDeadline = selectionScrollDirection(at: drag) == 0 ? nil : now.advanced(by: .milliseconds(50))
    mouseCapture = .selection(drag)
    return .redraw
  }

  func mouse(_ event: MouseEvent) -> ScreenUpdate {
    guard !helpVisible, !preparationFailed, let size = preparedSize,
      size.columns >= 16, size.rows >= 7
    else {
      mouseCapture = .idle
      return .none
    }
    let layout = DocumentViewerLayout(size: size, byteCount: source.byteCount, showInspector: showInspector)
    if case .selection = mouseCapture {
      switch event.action {
      case .move where event.button == .left:
        return extendSelection(event, layout: layout)
      case .release where event.button == .left || event.button == .none:
        let update = extendSelection(event, layout: layout)
        finishSelectionCapture()
        if selectionRange == nil { textSelection = nil }
        return update
      case .move:
        finishSelectionCapture()  // Recover when a release happened outside the terminal.
        if selectionRange == nil { textSelection = nil }
        return .none
      default: break
      }
    }
    var clearedSelection = false
    if event.action == .press && event.button == .left && event.modifiers.isEmpty {
      let hadSelection = selectionRange != nil
      clearedSelection = hadSelection
      let wasDraggingScrollbar = mouseCapture.isScrollbar
      clearSelection()
      if let range = selectionBytes(column: event.column, row: event.row, layout: layout, clamp: false) {
        textSelection = .init(byteRange: range)
        mouseCapture = .selection(.init(column: event.column, row: event.row))
        return hadSelection || wasDraggingScrollbar ? .redraw : .none
      }
      // A press outside the byte pane clears its highlight without capturing
      // clicks in the gutter, inspector, header, or footer.
      if hadSelection && event.column != layout.scrollbarColumn {
        mouseCapture = .idle
        return .redraw
      }
    }
    if event.action == .scrollUp || event.action == .scrollDown {
      guard event.modifiers.isEmpty,
        (layout.document.x..<layout.document.right).contains(event.column),
        (layout.text.y..<layout.text.bottom).contains(event.row)
      else { return .none }
      let wasDragging = mouseCapture.isScrollbar
      mouseCapture = .idle
      let previous = firstByte
      scroll(rows: event.action == .scrollUp ? -3 : 3)
      guard previous != firstByte || backwardRows > 0 else { return wasDragging ? .redraw : .none }
      return .redraw
    }
    guard
      let scrollbar = DocumentScrollbar(
        layout: layout, byteCount: source.byteCount, visibleBytes: visibleBytes, firstByte: firstByte),
      scrollbar.canDrag
    else {
      finishScrollbarCapture()
      return clearedSelection ? .redraw : .none
    }
    switch event.action {
    case .press:
      let wasDragging = mouseCapture.isScrollbar
      finishScrollbarCapture()
      guard event.button == .left, event.modifiers.isEmpty,
        scrollbar.contains(column: event.column, row: event.row)
      else { return wasDragging || clearedSelection ? .redraw : .none }
      let onThumb = scrollbar.thumbContains(row: event.row)
      let grab = onThumb ? event.row - scrollbar.thumbFirstRow : scrollbar.thumbRows / 2
      mouseCapture = .scrollbar(.init(grabOffsetRows: grab, lastPointerRow: event.row))
      if !onThumb { seekScrollbar(scrollbar, row: event.row, grab: grab) }
      return .redraw
    case .move:
      guard event.button == .left else {
        let wasDragging = mouseCapture.isScrollbar
        finishScrollbarCapture()
        return wasDragging ? .redraw : .none
      }
      return dragScrollbar(to: event.row, scrollbar: scrollbar)
    case .release:
      guard mouseCapture.isScrollbar, event.button == .left || event.button == .none else { return .none }
      _ = dragScrollbar(to: event.row, scrollbar: scrollbar)
      mouseCapture = .idle
      return .redraw
    case .scrollUp, .scrollDown, .scrollLeft, .scrollRight: return .none
    }
  }

  private func extendSelection(_ event: MouseEvent, layout: DocumentViewerLayout) -> ScreenUpdate {
    guard case .selection(var drag) = mouseCapture,
      let range = selectionBytes(column: event.column, row: event.row, layout: layout, clamp: true)
    else { return .none }
    let moved = drag.column != event.column || drag.row != event.row
    drag.column = event.column
    drag.row = event.row
    let changed = textSelection?.extend(to: range, moved: moved) == true
    if changed { selectionCopied = false }
    if selectionScrollDirection(at: drag) != 0 {
      if drag.scrollDeadline == nil { drag.scrollDeadline = ContinuousClock().now }
    } else {
      drag.scrollDeadline = nil
    }
    mouseCapture = .selection(drag)
    return changed ? .redraw : .none
  }

  private func dragScrollbar(to row: Int, scrollbar: DocumentScrollbar) -> ScreenUpdate {
    guard case .scrollbar(var drag) = mouseCapture, row != drag.lastPointerRow else { return .none }
    drag.lastPointerRow = row
    mouseCapture = .scrollbar(drag)
    let target = scrollbar.byteOffset(pointerRow: row, grabOffsetRows: drag.grabOffsetRows)
    guard target != firstByte else { return .none }
    seekScrollbar(scrollbar, row: row, grab: drag.grabOffsetRows)
    return .redraw
  }

  private func seekScrollbar(_ scrollbar: DocumentScrollbar, row: Int, grab: Int) {
    let target = scrollbar.byteOffset(pointerRow: row, grabOffsetRows: grab)
    firstByte = !source.isASCII && target == scrollbar.maximumFirstByte ? source.byteCount : target
    backwardRows = 0
  }

  private func selectionBytes(column: Int, row: Int, layout: DocumentViewerLayout, clamp: Bool) -> Range<Int>? {
    let width = min(layout.text.width, viewport.size.columns)
    let height = min(layout.text.height, viewport.size.rows)
    guard width > 0 && height > 0 else { return nil }
    if !clamp
      && (!(layout.text.x..<layout.text.x + width).contains(column)
        || !(layout.text.y..<layout.text.y + height).contains(row))
    {
      return nil
    }
    return viewport.byteRange(
      column: min(width - 1, max(0, column - layout.text.x)),
      row: min(height - 1, max(0, row - layout.text.y)), clamp: clamp)
  }

  func prepare(in size: TerminalSize) {
    guard !preparationFailed else { return }
    if preparedSize != size {
      mouseCapture = .idle
      clearSelection()
    }
    preparedSize = size
    let layout = DocumentViewerLayout(size: size, byteCount: source.byteCount, showInspector: showInspector)
    let requestedSize = TerminalSize(columns: layout.text.width, rows: layout.text.height)
    if source.isASCII || viewport.size != requestedSize { visibleBytes = requestedSize.columns * requestedSize.rows }
    rowBytes = max(1, requestedSize.columns)
    firstByte = min(firstByte, source.isASCII ? maximumFirstByte : source.byteCount)
    let preserveSelection = selectionScrollPending && viewport.size == requestedSize
    selectionScrollPending = false
    if (viewport.size != requestedSize || viewport.visibleRange.lowerBound != firstByte || backwardRows > 0)
      && !preserveSelection
    {
      clearSelection()
    }
    if !reloadRequested, let request = viewportRequest,
      request.firstByte == firstByte && request.size == requestedSize
    {
      return
    }
    if !reloadRequested && !preparationFailed && viewport.size == requestedSize
      && viewport.visibleRange.lowerBound == firstByte && backwardRows == 0
    {
      // Help redraws must not replace the last navigation's counters, but still
      // detect a changed snapshot even when no byte request is necessary.
      do throws(FileDocumentError) { try source.verifyUnchanged() } catch {
        preparationFailed = true
        mouseCapture = .idle
        clearSelection()
        notice = Self.message(for: error)
      }
      return
    }
    let before = source.statistics
    let oldRange = viewport.visibleRange
    viewportRequest = .init(
      firstByte: firstByte, size: requestedSize, statistics: before, previousRange: oldRange,
      preserveSelection: preserveSelection)
    do throws(FileDocumentError) {
      try viewport.begin(from: &source, firstByte: firstByte, size: requestedSize, backwardRows: backwardRows)
      backwardRows = 0
      if viewport.hasPendingWork { _ = try viewport.advance(from: &source) }
      if !viewport.hasPendingWork { completeViewport() }
    } catch {
      preparationFailed = true
      mouseCapture = .idle
      clearSelection()
      firstByte = viewport.visibleRange.lowerBound
      notice = Self.message(for: error)
      viewportRequest = nil
    }
    reloadRequested = false
    if !viewport.hasPendingWork || preparationFailed { updateReadStatistics(since: before) }
  }

  private func advanceViewport() -> ScreenUpdate {
    guard let request = viewportRequest else { preconditionFailure("Pending viewport has no request") }
    do throws(FileDocumentError) {
      let complete = try viewport.advance(from: &source)
      if complete {
        updateReadStatistics(since: request.statistics)
        completeViewport()
        return .redraw
      }
      return .none
    } catch {
      preparationFailed = true
      viewportRequest = nil
      mouseCapture = .idle
      clearSelection()
      firstByte = viewport.visibleRange.lowerBound
      notice = Self.message(for: error)
      updateReadStatistics(since: request.statistics)
      return .redraw
    }
  }

  private func completeViewport() {
    guard let request = viewportRequest else { preconditionFailure("Completed viewport has no request") }
    previousRange = request.previousRange
    firstByte = viewport.visibleRange.lowerBound
    if !source.isASCII { visibleBytes = viewport.visibleRange.count }
    preparationFailed = false
    notice = ""
    viewportRequest = nil
    if request.preserveSelection, case .selection(var drag) = mouseCapture, let size = preparedSize {
      let layout = DocumentViewerLayout(size: size, byteCount: source.byteCount, showInspector: showInspector)
      if let range = selectionBytes(column: drag.column, row: drag.row, layout: layout, clamp: true) {
        _ = textSelection?.extend(to: range)
      }
      if selectionScrollDirection(at: drag) == 0 { drag.scrollDeadline = nil }
      mouseCapture = .selection(drag)
    }
  }

  private func updateReadStatistics(since before: FilePageStatistics) {
    lastPageLoads = source.statistics.loads - before.loads
    lastBytesRead = source.statistics.bytesRead - before.bytesRead
    lastEvictions = source.statistics.evictions - before.evictions
    lastCacheHits = source.statistics.cacheHits - before.cacheHits
    for slot in 0..<source.configuration.cachePages {
      let page = source.cachedPageNumber(at: slot) ?? -1
      freshSlots[slot] = page >= 0 && page != cachedPages[slot]
      cachedPages[slot] = page
    }
  }

  func paint(in frame: inout Frame) {
    let size = documentSize(in: TerminalSize(columns: frame.area.width, rows: frame.area.height))
    let area = Rect(width: size.columns, height: size.rows)
    frame.fill(area, with: Cell(style: ViewerPalette.body))
    guard area.height >= 7 && area.width >= 16 else {
      frame.text("Resize to 16 x 7; Q quits", in: area, style: ViewerPalette.muted)
      return
    }
    let layout = DocumentViewerLayout(
      size: size, byteCount: source.byteCount, showInspector: showInspector)
    paintHeader(layout: layout, frame: &frame)
    if layout.rich { frame.border(layout.document, title: " FILE BYTES ", style: ViewerPalette.border) }
    viewport.paint(
      in: layout.text, frame: &frame, pageBytes: source.configuration.pageBytes,
      previousRange: previousRange, style: ViewerPalette.body,
      revealedStyle: ViewerPalette.revealed, boundaryStyle: ViewerPalette.accent,
      selection: selectionRange, selectionStyle: ViewerPalette.selection,
      match: search.match, matchStyle: ViewerPalette.match)
    paintRows(layout: layout, frame: &frame)
    paintScrollbar(layout: layout, frame: &frame)
    if let inspector = layout.inspector { paintInspector(in: inspector, frame: &frame) }
    paintFooter(layout: layout, height: area.height, frame: &frame)
    if helpVisible { paintHelp(height: area.height, frame: &frame) }
  }

  private func paintHeader(layout: DocumentViewerLayout, frame: inout Frame) {
    frame.fill(Rect(width: frame.area.width, height: 1), with: Cell(style: ViewerPalette.header))
    label(" SLATE / FILE READER", x: 0, y: 0, width: frame.area.width, style: ViewerPalette.header, frame: &frame)
    if frame.area.width >= 48 {
      label("READ ONLY", x: frame.area.width - 11, y: 0, width: 10, style: ViewerPalette.header, frame: &frame)
    }
    label(displayName, x: 1, y: 1, width: frame.area.width - 2, style: ViewerPalette.title, frame: &frame)
    guard layout.rich else { return }
    label("UTF-8 BYTE VIEW", x: 1, y: 2, width: 16, style: ViewerPalette.muted, frame: &frame)
    number(source.configuration.pageBytes, x: 18, y: 2, width: 7, frame: &frame)
    label("B/page", x: 26, y: 2, width: 6, style: ViewerPalette.muted, frame: &frame)
    number(source.indexedPageCount, x: 33, y: 2, width: 7, frame: &frame)
    label("pages", x: 41, y: 2, width: 5, style: ViewerPalette.muted, frame: &frame)
    if frame.area.width >= 64 {
      number(source.byteCount, x: frame.area.width - 17, y: 2, width: 10, frame: &frame)
      label("bytes", x: frame.area.width - 6, y: 2, width: 5, style: ViewerPalette.muted, frame: &frame)
    }
  }

  private func paintRows(layout: DocumentViewerLayout, frame: inout Frame) {
    guard viewport.size.columns > 0 else { return }
    for row in 0..<min(layout.text.height, viewport.size.rows) {
      guard let range = viewport.rowRange(at: row) else { break }
      let offset = range.lowerBound
      let end = range.upperBound
      let revealed = !previousRange.isEmpty && (offset < previousRange.lowerBound || end > previousRange.upperBound)
      let y = layout.text.y + row
      if layout.text.x > 0 {
        let x = layout.rich ? 2 : 1
        number(
          offset, x: x, y: y, width: layout.gutterDigits,
          style: revealed ? ViewerPalette.fresh : ViewerPalette.muted, frame: &frame)
        if revealed { frame[x - 1, y] = Cell(Glyph(">")!, style: ViewerPalette.fresh) }
        frame[layout.text.x - 1, y] = Cell(Glyph("│")!, style: ViewerPalette.border)
      }
    }
  }

  private func paintScrollbar(layout: DocumentViewerLayout, frame: inout Frame) {
    guard
      let scrollbar = DocumentScrollbar(
        layout: layout, byteCount: source.byteCount, visibleBytes: viewport.visibleRange.count,
        firstByte: viewport.visibleRange.lowerBound)
    else { return }
    for row in scrollbar.firstRow..<scrollbar.firstRow + scrollbar.rowCount {
      let active = scrollbar.thumbContains(row: row)
      let thumbStyle = mouseCapture.isScrollbar ? ViewerPalette.fresh : ViewerPalette.accent
      frame[scrollbar.column, row] = Cell(
        Glyph(active ? "┃" : "│")!, style: active ? thumbStyle : ViewerPalette.border)
    }
  }

  private func paintInspector(in area: Rect, frame: inout Frame) {
    frame.border(area, title: " PAGE CACHE ", style: ViewerPalette.border)
    let x = area.x + 2
    label("Byte cache KiB", x: x, y: area.y + 1, width: 17, style: ViewerPalette.muted, frame: &frame)
    number(
      source.configuration.pageBytes * source.configuration.cachePages / 1_024,
      x: area.right - 9, y: area.y + 1, width: 6, frame: &frame)
    label("Page loads", x: x, y: area.y + 2, width: 15, style: ViewerPalette.muted, frame: &frame)
    counter(source.statistics.loads, x: area.right - 10, y: area.y + 2, width: 7, frame: &frame)
    label("Evictions", x: x, y: area.y + 3, width: 15, style: ViewerPalette.muted, frame: &frame)
    counter(source.statistics.evictions, x: area.right - 10, y: area.y + 3, width: 7, frame: &frame)
    label("Read KiB", x: x, y: area.y + 4, width: 15, style: ViewerPalette.muted, frame: &frame)
    counter(source.statistics.bytesRead / 1_024, x: area.right - 12, y: area.y + 4, width: 9, frame: &frame)
    label(
      "SLOT PAGE        BYTE OFFSET", x: x, y: area.y + 5, width: area.width - 4,
      style: ViewerPalette.title, frame: &frame)
    let rows = min(source.configuration.cachePages, max(0, area.height - 8))
    for slot in 0..<rows {
      let y = area.y + 6 + slot
      number(slot, x: x, y: y, width: 2, frame: &frame)
      if cachedPages[slot] >= 0 {
        let style = freshSlots[slot] ? ViewerPalette.fresh : ViewerPalette.accent
        label(freshSlots[slot] ? "+" : "#", x: x + 3, y: y, width: 1, style: style, frame: &frame)
        number(cachedPages[slot], x: x + 5, y: y, width: 7, style: style, frame: &frame)
        number(
          cachedPages[slot] * source.configuration.pageBytes,
          x: x + 15, y: y, width: 12, style: style, frame: &frame)
      } else {
        label("empty", x: x + 5, y: y, width: 10, style: ViewerPalette.muted, frame: &frame)
      }
    }
    label("Resident / slots", x: x, y: area.bottom - 2, width: 17, style: ViewerPalette.muted, frame: &frame)
    number(source.residentPageCount, x: area.right - 9, y: area.bottom - 2, width: 2, frame: &frame)
    label("/", x: area.right - 6, y: area.bottom - 2, width: 1, style: ViewerPalette.muted, frame: &frame)
    number(source.configuration.cachePages, x: area.right - 4, y: area.bottom - 2, width: 2, frame: &frame)
  }

  private func paintFooter(layout: DocumentViewerLayout, height: Int, frame: inout Frame) {
    let y = height - (layout.rich ? 4 : 3)
    let width = frame.area.width
    if preparationFailed {
      label(notice, x: 1, y: y, width: width - 2, style: ViewerPalette.error, frame: &frame)
    } else {
      label("BYTE", x: 1, y: y, width: 4, style: ViewerPalette.muted, frame: &frame)
      number(viewport.visibleRange.lowerBound, x: 6, y: y, width: 13, frame: &frame)
      label("OF", x: 21, y: y, width: 2, style: ViewerPalette.muted, frame: &frame)
      number(source.byteCount, x: 24, y: y, width: 13, frame: &frame)
      let distance = max(0, source.byteCount - viewport.visibleRange.count)
      let percent = distance == 0 ? 100 : viewport.visibleRange.lowerBound * 100 / distance
      number(percent, x: 39, y: y, width: 3, style: ViewerPalette.accent, frame: &frame)
      label("%", x: 42, y: y, width: 1, style: ViewerPalette.accent, frame: &frame)
      if width >= 80 {
        label("READ B", x: 46, y: y, width: 6, style: ViewerPalette.muted, frame: &frame)
        counter(lastBytesRead, x: 53, y: y, width: 10, frame: &frame)
        label("EVICT", x: 65, y: y, width: 5, style: ViewerPalette.muted, frame: &frame)
        counter(lastEvictions, x: 71, y: y, width: 5, frame: &frame)
      }
      if width >= 100 {
        label("HITS", x: 79, y: y, width: 4, style: ViewerPalette.muted, frame: &frame)
        counter(lastCacheHits, x: 84, y: y, width: 7, frame: &frame)
      }
    }
    let mapY = y + 1
    label("FILE", x: 1, y: mapY, width: 5, style: ViewerPalette.muted, frame: &frame)
    let buckets = max(0, min(64, width - 28))
    for bucket in 0..<buckets {
      var resident = false
      var fresh = false
      for slot in 0..<source.configuration.cachePages where cachedPages[slot] >= 0 {
        if cachedPages[slot] * buckets / max(1, source.indexedPageCount) == bucket {
          resident = true
          fresh = fresh || freshSlots[slot]
        }
      }
      frame[7 + bucket, mapY] = Cell(
        Glyph(fresh ? "+" : resident ? "#" : ".")!,
        style: fresh ? ViewerPalette.fresh : resident ? ViewerPalette.accent : ViewerPalette.border)
    }
    label(
      lastPageLoads > 0 ? "LOAD +" : "CACHED", x: 9 + buckets, y: mapY, width: 8,
      style: lastPageLoads > 0 ? ViewerPalette.fresh : ViewerPalette.accent, frame: &frame)
    if lastPageLoads > 0 { counter(lastPageLoads, x: 17 + buckets, y: mapY, width: 4, frame: &frame) }
    let helpY = height - 1
    label(
      selectionRange != nil
        ? "y / Ctrl-C copy  Esc clear selection"
        : layout.rich ? "/ search  j/k row  PgUp/Dn screen  0-9 jump  C clear" : "/ search  j/k row  0-9 jump",
      x: 1, y: helpY, width: width - 17, style: ViewerPalette.muted, frame: &frame)
    label("? help  Q quit", x: max(1, width - 15), y: helpY, width: 14, style: ViewerPalette.muted, frame: &frame)
    if layout.rich {
      if let range = selectionRange {
        label(
          selectionCopied ? "COPIED" : "SELECTED", x: 1, y: helpY - 1, width: 9,
          style: ViewerPalette.accent, frame: &frame)
        number(range.count, x: 11, y: helpY - 1, width: 13, frame: &frame)
        label(
          "file bytes; gutter and cache excluded",
          x: 26, y: helpY - 1, width: width - 28,
          style: ViewerPalette.muted, frame: &frame)
      } else {
        label(
          "> new bytes   underline: page start   + loaded   # resident   . uncached",
          x: 1, y: helpY - 1, width: width - 2, style: ViewerPalette.muted, frame: &frame)
      }
    }
  }

  private func paintHelp(height availableHeight: Int, frame: inout Frame) {
    let width = min(76, frame.area.width - 2)
    let height = min(helpLines.count + 3, availableHeight - 2)
    guard width > 4 && height > 3 else { return }
    let area = Rect(
      x: (frame.area.width - width) / 2, y: (availableHeight - height) / 2, width: width, height: height)
    frame.fill(area, with: Cell(style: ViewerPalette.body))
    frame.border(area, title: " FILE READER / HELP ", style: ViewerPalette.accent)
    for row in 0..<min(helpLines.count, height - 2) {
      label(
        helpLines[row], x: area.x + 2, y: area.y + 1 + row, width: area.width - 4,
        style: row == 0 || helpLines[row] == "WATCH THE READER" ? ViewerPalette.title : ViewerPalette.muted, frame: &frame)
    }
  }

  static func message(for error: FileDocumentError) -> String {
    switch error {
    case .open: return "Cannot open the file. Check its path and permissions."
    case .inspect: return "Cannot inspect the file."
    case .notRegularFile: return "Only regular files are supported."
    case .indexCapacityExceeded: return "File exceeds the configured page index limit (4 GiB by default)."
    case .read: return "A file read failed. Reopen the file to retry."
    case .fileChanged: return "File changed while open. Reopen it; the previous viewport is preserved."
    case .invalidUTF8: return "The file is not valid UTF-8."
    case .invalidPath: return "Invalid file path."
    case .invalidConfiguration, .invalidRange, .invalidLine: return "Invalid document configuration or range."
    }
  }

  private func label(_ text: String, x: Int, y: Int, width: Int, style: Style, frame: inout Frame) {
    guard x >= 0 && x < frame.area.width && y >= 0 && y < frame.area.height && width > 0 else { return }
    frame.text(text, in: Rect(x: x, y: y, width: min(width, frame.area.width - x), height: 1), style: style)
  }

  private func number(_ value: Int, x: Int, y: Int, width: Int, style: Style = ViewerPalette.muted, frame: inout Frame)
  {
    counter(UInt64(max(0, value)), x: x, y: y, width: width, style: style, frame: &frame)
  }

  private func counter(
    _ value: UInt64, x: Int, y: Int, width: Int, style: Style = ViewerPalette.muted, frame: inout Frame
  ) {
    guard x >= 0 && x < frame.area.width && y >= 0 && y < frame.area.height && width > 0 else { return }
    var remainder = value
    for column in stride(from: x + width - 1, through: x, by: -1) {
      if column < frame.area.width {
        frame[column, y] = Cell(Glyph(Unicode.Scalar(UInt8(remainder % 10) + 0x30))!, style: style)
      }
      remainder /= 10
      if remainder == 0 { break }
    }
    if remainder > 0 { frame[x, y] = Cell(Glyph("#")!, style: style) }
  }
}

enum ViewerPalette {
  static var match: Style { Style(foreground: .black, background: .indexed(220)) }
  static var selection: Style { Style(foreground: .white, background: .indexed(60)) }
  static var body: Style { Style(foreground: .indexed(252), background: .indexed(234)) }
  static var revealed: Style { Style(foreground: .indexed(252), background: .indexed(236)) }
  static var muted: Style { Style(foreground: .indexed(244), background: .indexed(234)) }
  static var title: Style { Style(foreground: .indexed(255), background: .indexed(234), bold: true) }
  static var accent: Style { Style(foreground: .indexed(81), background: .indexed(234), bold: true) }
  static var fresh: Style { Style(foreground: .indexed(114), background: .indexed(234), bold: true) }
  static var border: Style { Style(foreground: .indexed(239), background: .indexed(234)) }
  static var error: Style { Style(foreground: .indexed(215), background: .indexed(234)) }
  static var header: Style { Style(foreground: .indexed(255), background: .indexed(24), bold: true) }
}
