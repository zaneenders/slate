import _RopeModule

/// This private rope is an immutable index of indivisible disk-page references.
/// It is built once during open. Lookup uses find's remainder, never the metric
/// operation that asks for an interior element index. Text stays on disk.
struct FilePageIndex {
  private var pages = Rope<FilePageReference>()
  private(set) var pageCount = 0
  let capacity: Int

  var byteCount: Int { pages.count(in: FileByteMetric()) }
  var breakCount: Int { pages.count(in: FileBreakMetric()) }

  mutating func append(_ page: FilePageReference) throws(FileDocumentError) {
    guard pageCount < capacity else { throw .indexCapacityExceeded }
    precondition(page.byteCount > 0)
    page.invariantCheck()
    precondition(page.fileOffset == byteCount)
    pages.append(page)
    pageCount += 1
  }

  func page(atByteOffset offset: Int) -> FilePageReference {
    precondition((0..<byteCount).contains(offset))
    let found = pages.find(at: offset, in: FileByteMetric(), preferEnd: false)
    return pages[found.index]
  }

  func page(containingBreak ordinal: Int) -> (page: FilePageReference, localOrdinal: Int) {
    precondition((0..<breakCount).contains(ordinal))
    let found = pages.find(at: ordinal, in: FileBreakMetric(), preferEnd: false)
    return (pages[found.index], found.remaining)
  }
}

struct FilePageSummary: RopeSummary {
  var bytes: Int
  var breaks: Int
  static let maxNodeSize = 15
  static var zero: Self { Self(bytes: 0, breaks: 0) }
  var isZero: Bool { bytes == 0 && breaks == 0 }

  mutating func add(_ other: Self) {
    bytes += other.bytes
    breaks += other.breaks
  }

  mutating func subtract(_ other: Self) {
    bytes -= other.bytes
    breaks -= other.breaks
  }
}

struct FilePageReference: RopeElement, Sendable {

  enum Index: Int, Comparable {
    case start, end
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  let fileOffset: Int
  let byteCount: Int
  let breakCount: Int
  let previousWasCR: Bool
  let checksum: UInt64
  var unicodeCheckpoint = FileUnicodeCheckpoint()

  var summary: FilePageSummary { .init(bytes: byteCount, breaks: breakCount) }
  var isEmpty: Bool { byteCount == 0 }
  var isUndersized: Bool { false }

  func invariantCheck() {
    precondition(fileOffset >= 0 && byteCount >= 0 && breakCount >= 0 && breakCount <= byteCount)
  }

  mutating func rebalance(nextNeighbor right: inout Self) -> Bool {
    if isEmpty {
      self = right
      right = .empty
      return true
    }
    return right.isEmpty
  }

  mutating func split(at index: Index) -> Self {
    if index == .end { return .empty }
    let original = self
    self = .empty
    return original
  }

  private static var empty: Self {
    .init(fileOffset: 0, byteCount: 0, breakCount: 0, previousWasCR: false, checksum: 0)
  }
}

private struct FileByteMetric: RopeMetric {

  func size(of summary: FilePageSummary) -> Int {
    summary.bytes
  }

  func index(at offset: Int, in element: FilePageReference) -> FilePageReference.Index {
    precondition(offset == 0 || offset == element.byteCount, "Disk pages are indivisible")
    return offset == 0 ? .start : .end
  }
}

private struct FileBreakMetric: RopeMetric {

  func size(of summary: FilePageSummary) -> Int {
    summary.breaks
  }

  func index(at offset: Int, in element: FilePageReference) -> FilePageReference.Index {
    precondition(offset == 0 || offset == element.breakCount, "Disk pages are indivisible")
    return offset == 0 ? .start : .end
  }
}
