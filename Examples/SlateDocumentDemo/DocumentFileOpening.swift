import Slate

struct FileIndexingProgress: Equatable, Sendable {
  let indexedBytes: Int
  let totalBytes: Int
  let indexedPages: Int
  let totalPages: Int
}

/// Initialization owner. Opening only inspects the file and allocates bounded
/// cache storage; advance performs the scan. Painting observes scalar progress
/// and never reads the file or allocates Strings. Rope growth remains confined
/// to this initialization phase, within the reader's documented index budget.
final class DocumentFileOpening: ~Sendable {
  private var indexer: PagedFileDocument.Indexer?
  private let path: String
  private let displayName: String
  private let totalBytes: Int
  private let configuration: FileDocumentConfiguration

  init(_ path: String, configuration: FileDocumentConfiguration = .init()) throws(FileDocumentError) {
    let indexer = try PagedFileDocument.Indexer(path, configuration: configuration, content: .bytes)
    totalBytes = indexer.byteCount
    self.indexer = consume indexer
    self.configuration = configuration
    self.path = path
    if let slash = path.lastIndex(of: "/") {
      displayName = String(path[path.index(after: slash)...])
    } else {
      displayName = path
    }
  }

  var isComplete: Bool { indexer?.isComplete ?? true }
  var progress: FileIndexingProgress {
    .init(
      indexedBytes: indexer?.indexedByteCount ?? totalBytes, totalBytes: totalBytes,
      indexedPages: indexer?.indexedPageCount ?? totalPages, totalPages: totalPages)
  }
  private var totalPages: Int { (totalBytes + configuration.pageBytes - 1) / configuration.pageBytes }

  func advance() throws(FileDocumentError) {
    precondition(indexer != nil)
    try indexer?.advance()
  }

  func finish() -> DocumentFileViewer {
    guard let indexer = indexer.take() else { preconditionFailure("The indexed document was already transferred") }
    return DocumentFileViewer(path, source: indexer.finish())
  }

  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: ViewerPalette.body))
    guard frame.area.width >= 36 && frame.area.height >= 12 else {
      label("Indexing file... Q quits", x: 0, y: 0, width: frame.area.width, frame: &frame)
      return
    }
    frame.fill(Rect(width: frame.area.width, height: 1), with: Cell(style: ViewerPalette.header))
    label(" SLATE / FILE READER", x: 0, y: 0, width: frame.area.width, style: ViewerPalette.header, frame: &frame)
    label(displayName, x: 1, y: 1, width: frame.area.width - 2, style: ViewerPalette.title, frame: &frame)
    let area = Rect(x: 1, y: 3, width: frame.area.width - 2, height: min(14, frame.area.height - 5))
    frame.border(area, title: " INDEXING FILE ", style: ViewerPalette.accent)
    let x = area.x + 2
    let y = area.y + 1
    label("Scanning bytes and building the page index.", x: x, y: y, width: area.width - 4, frame: &frame)
    let progress = self.progress
    number(progress.indexedBytes, x: x, y: y + 2, width: 13, frame: &frame)
    label("/", x: x + 14, y: y + 2, width: 1, frame: &frame)
    number(progress.totalBytes, x: x + 16, y: y + 2, width: 13, frame: &frame)
    if area.width >= 40 { label("bytes", x: x + 30, y: y + 2, width: 5, frame: &frame) }
    let barWidth = area.width - 12
    let filled = progress.totalBytes == 0 ? 0 : barWidth * progress.indexedBytes / progress.totalBytes
    for column in 0..<barWidth {
      frame[x + column, y + 3] = Cell(
        Glyph(column < filled ? "#" : "─")!,
        style: column < filled ? ViewerPalette.accent : ViewerPalette.border)
    }
    let percent = progress.totalBytes == 0 ? 0 : progress.indexedBytes * 100 / progress.totalBytes
    number(percent, x: x + barWidth + 1, y: y + 3, width: 3, frame: &frame)
    label("%", x: x + barWidth + 4, y: y + 3, width: 1, frame: &frame)
    if area.height >= 12 && area.width >= 40 {
      label("Disk pages", x: x, y: y + 5, width: 11, frame: &frame)
      number(progress.indexedPages, x: x + 12, y: y + 5, width: 8, frame: &frame)
      label("/", x: x + 21, y: y + 5, width: 1, frame: &frame)
      number(progress.totalPages, x: x + 23, y: y + 5, width: 8, frame: &frame)
      label(
        "Bytes stay on disk; cached pages start empty.",
        x: x, y: y + 7, width: area.width - 4, frame: &frame)
      label(
        "The viewer opens automatically when indexing finishes.",
        x: x, y: y + 8, width: area.width - 4, frame: &frame)
    }
    label(
      "Q / Escape / Ctrl-C: cancel", x: 1, y: frame.area.height - 1,
      width: frame.area.width - 2, frame: &frame)
  }

  private func label(
    _ text: String, x: Int, y: Int, width: Int, style: Style = ViewerPalette.muted, frame: inout Frame
  ) {
    guard x < frame.area.width && y < frame.area.height && width > 0 else { return }
    frame.text(text, in: Rect(x: x, y: y, width: min(width, frame.area.width - x), height: 1), style: style)
  }

  private func number(_ value: Int, x: Int, y: Int, width: Int, frame: inout Frame) {
    guard x < frame.area.width && y < frame.area.height else { return }
    var remainder = value
    for column in stride(from: x + width - 1, through: x, by: -1) {
      if column < frame.area.width {
        frame[column, y] = Cell(Glyph(Unicode.Scalar(UInt8(remainder % 10) + 0x30))!, style: ViewerPalette.title)
      }
      remainder /= 10
      if remainder == 0 { break }
    }
    if remainder > 0 { frame[x, y] = Cell(Glyph("#")!, style: ViewerPalette.title) }
  }
}
