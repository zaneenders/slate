import BasicContainers
import Slate
import SystemPackage

// Stat exposes platform timespec values; their fields require a direct import.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
import Musl
#endif

enum FileDocumentError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidPath
  case open(errno: Int32)
  case inspect(errno: Int32)
  case notRegularFile
  case indexCapacityExceeded
  case read(errno: Int32)
  case fileChanged
  case invalidUTF8(byteOffset: Int)
  case invalidRange
  case invalidLine
}

struct FileDocumentConfiguration: Sendable {
  var pageBytes = 65_536
  var cachePages = 8
  var maximumPages = 65_536

  var maximumFileBytes: Int { pageBytes * maximumPages }

  func validate() throws(FileDocumentError) {
    guard Int.bitWidth >= 64, (4...1_048_576).contains(pageBytes), (1...64).contains(cachePages),
      (1...1_048_576).contains(maximumPages), pageBytes * cachePages <= 16_777_216
    else { throw .invalidConfiguration }
  }
}

/// Text consumers require UTF-8; byte viewers accept every byte value. Both
/// policies use the same bounded index, checksums, and cache storage.
enum FileContentPolicy {
  case utf8
  case bytes
}

struct FilePageStatistics: Equatable, Sendable {
  private(set) var cacheHits: UInt64 = 0
  private(set) var loads: UInt64 = 0
  private(set) var bytesRead: UInt64 = 0
  private(set) var evictions: UInt64 = 0

  mutating func hit() { cacheHits += cacheHits < .max ? 1 : 0 }

  mutating func loaded(bytes: Int, evicted: Bool) {
    loads += loads < .max ? 1 : 0
    bytesRead += min(UInt64(bytes), .max - bytesRead)
    if evicted { evictions += evictions < .max ? 1 : 0 }
  }
}

/// Read-only file prototype. All byte caching storage is allocated once. The
/// experimental Collections rope stores only page descriptors, with initialization-only
/// allocations bounded by maximumPages. No rope mutation occurs after indexing.
///
/// Default cache: 8 * 64 KiB of bytes + 8 * 64 KiB * 4-byte newline offsets =
/// 2.5 MiB, plus fixed slot metadata. The resident rope index scales with file
/// size, bounded separately (65,536 descriptors / 4 GiB of text by default).
/// This pages text, not the rope's own nodes. A conservative index allowance is
/// 256 bytes per permitted descriptor + 4 KiB for the pinned 15-way tree.
///
/// Indexer scans/validates in cooperative batches, then transfers the completed
/// document without copying buffers. Rope allocations belong to initialization,
/// which may run inside the UI. Successful steady reads reuse buffers and allocate
/// no storage after runtime warm-up; error propagation may allocate an error box.
/// One caller, no retained page borrows, no tasks.
/// Each line lookup touches at most three pages; reads touch one page. Syscall latency
/// is outside the CPU work bound. File mutation is an explicit failure.
/// Byte mode records the first UTF-8 error without allocating or restarting the
/// scan. TextDocumentSource operations still reject that malformed snapshot.
struct PagedFileDocument: TextDocumentSource, ~Copyable, ~Sendable {
  typealias ReadError = FileDocumentError
  private let file: OwnedDocumentFile
  private let identity: DocumentFileIdentity
  let configuration: FileDocumentConfiguration
  private var index: FilePageIndex
  private var bytes: RigidArray<UInt8>
  private var breaks: RigidArray<UInt32>
  private var slots: RigidArray<CachedFilePage>
  private var clock: UInt64 = 0
  private var invalidUTF8ByteOffset: Int?
  private(set) var statistics = FilePageStatistics()
  private(set) var isASCII = true

  var byteCount: Int { identity.byteCount }
  var snapshotIdentity: DocumentFileIdentity { identity }
  var lineCount: Int { index.breakCount + 1 }
  var indexedPageCount: Int { index.pageCount }
  var residentPageCount: Int {
    var result = 0
    for slot in 0..<slots.count where slots[slot].fileOffset >= 0 { result += 1 }
    return result
  }
  var cacheStorageBudgetBytes: Int {
    bytes.count + breaks.count * MemoryLayout<UInt32>.stride
      + slots.count * MemoryLayout<CachedFilePage>.stride
  }
  var indexMetadataAllowanceBytes: Int { configuration.maximumPages * 256 + 4_096 }

  borrowing func unicodeCheckpoint(before offset: Int) -> FileUnicodeCheckpoint {
    guard byteCount > 0 else { return .init() }
    return index.page(atByteOffset: min(offset, byteCount - 1)).unicodeCheckpoint
  }

  borrowing func cachedPageNumber(at slot: Int) -> Int? {
    guard (0..<slots.count).contains(slot), slots[slot].fileOffset >= 0 else { return nil }
    return slots[slot].fileOffset / configuration.pageBytes
  }

  /// Drops residency only; fixed buffers, the index, and cumulative counters are
  /// retained. The next read demonstrates a cold cache without reopening a file.
  mutating func discardCachedPages() {
    for slot in 0..<slots.count { slots[slot] = CachedFilePage() }
  }

  static func open(
    _ path: String, configuration: FileDocumentConfiguration = .init(),
    content: FileContentPolicy = .utf8,
    progress: ((Int, Int) -> Void)? = nil
  ) throws(FileDocumentError) -> Self {
    var indexer = try Indexer(path, configuration: configuration, content: content)
    var nextProgressBytes = 67_108_864
    progress?(0, indexer.byteCount)
    while !indexer.isComplete {
      try indexer.advance()
      if indexer.indexedByteCount >= nextProgressBytes || (indexer.isComplete && indexer.byteCount > 0) {
        progress?(indexer.indexedByteCount, indexer.byteCount)
        nextProgressBytes = indexer.indexedByteCount + 67_108_864
      }
    }
    return indexer.finish()
  }

  private init(
    file: consuming OwnedDocumentFile, identity: DocumentFileIdentity, configuration: FileDocumentConfiguration
  ) {
    self.file = consume file
    self.identity = identity
    self.configuration = configuration
    index = FilePageIndex(capacity: configuration.maximumPages)
    bytes = RigidArray(repeating: 0, count: configuration.pageBytes * configuration.cachePages)
    breaks = RigidArray(repeating: 0, count: configuration.pageBytes * configuration.cachePages)
    slots = RigidArray(repeating: CachedFilePage(), count: configuration.cachePages)
  }

  borrowing func verifyUnchanged() throws(FileDocumentError) {
    guard try file.identity() == identity else { throw .fileChanged }
  }

  borrowing func validateSnapshot() throws(FileDocumentError) {
    try requireUTF8()
    try verifyUnchanged()
  }

  private borrowing func requireUTF8() throws(FileDocumentError) {
    if let invalidUTF8ByteOffset { throw .invalidUTF8(byteOffset: invalidUTF8ByteOffset) }
  }

  mutating func lineContentRange(at line: Int) throws(FileDocumentError) -> Range<Int> {
    try requireUTF8()
    guard (0..<lineCount).contains(line) else { throw .invalidLine }
    let start = line == 0 ? 0 : try offsetAfterBreak(line - 1)
    let end = line == lineCount - 1 ? byteCount : try breakOffset(line)
    guard start <= end else { throw .fileChanged }
    return start..<end
  }

  /// Text access requires a valid UTF-8 snapshot, including when opened in byte mode.
  mutating func readUTF8(
    from byteOffset: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(FileDocumentError) -> Int {
    try requireUTF8()
    return try readBytes(from: byteOffset, into: buffer)
  }

  /// Copies raw file bytes, including malformed UTF-8, into caller-owned storage.
  /// Copies at most maximumCount bytes, stopping at buffer or page boundaries
  /// and leaving unused buffer contents unchanged. A negative limit throws
  /// invalidRange; zero returns without cache access. Like readUTF8, each call
  /// touches at most one cached disk page.
  mutating func readBytes(
    from byteOffset: Int, maximumCount: Int = .max, into buffer: consuming MutableSpan<UInt8>
  ) throws(FileDocumentError) -> Int {
    guard (0...byteCount).contains(byteOffset), maximumCount >= 0 else { throw .invalidRange }
    guard byteOffset < byteCount && maximumCount > 0 && !buffer.isEmpty else { return 0 }
    let page = index.page(atByteOffset: byteOffset)
    let slot = try load(page)
    let local = byteOffset - page.fileOffset
    let count = min(maximumCount, min(buffer.count, page.byteCount - local))
    var buffer = consume buffer
    let base = slot * configuration.pageBytes + local
    for offset in 0..<count { buffer[offset] = bytes[base + offset] }
    return count
  }

  private mutating func breakOffset(_ ordinal: Int) throws(FileDocumentError) -> Int {
    let found = index.page(containingBreak: ordinal)
    let slot = try load(found.page)
    return found.page.fileOffset + Int(breaks[slot * configuration.pageBytes + found.localOrdinal])
  }

  private mutating func offsetAfterBreak(_ ordinal: Int) throws(FileDocumentError) -> Int {
    let offset = try breakOffset(ordinal)
    let value = try byte(at: offset)
    if value == 0x0d && offset + 1 < byteCount {
      if try byte(at: offset + 1) == 0x0a { return offset + 2 }
    }
    return offset + 1
  }

  private mutating func byte(at offset: Int) throws(FileDocumentError) -> UInt8 {
    let page = index.page(atByteOffset: offset)
    let slot = try load(page)
    return bytes[slot * configuration.pageBytes + offset - page.fileOffset]
  }

  private mutating func load(_ page: FilePageReference) throws(FileDocumentError) -> Int {
    if clock == .max {
      // On counter exhaustion discard only recency ordering, never page data.
      for slot in 0..<slots.count { slots[slot].age = 0 }
      clock = 0
    }
    clock += 1
    var victim = 0
    for slot in 0..<slots.count {
      if slots[slot].fileOffset == page.fileOffset {
        slots[slot].age = clock
        statistics.hit()
        return slot
      }
      if slots[victim].fileOffset >= 0 && (slots[slot].fileOffset < 0 || slots[slot].age < slots[victim].age) {
        victim = slot
      }
    }
    let evicted = slots[victim].fileOffset >= 0
    // A failed or partial read must never leave overwritten cache bytes valid.
    slots[victim] = CachedFilePage()
    let base = victim * configuration.pageBytes
    do {
      var storage = bytes.mutableSpan
      try file.readExactly(
        from: page.fileOffset, into: storage._mutatingExtracting(base..<base + page.byteCount))
    }
    var checksum: UInt64 = 14_695_981_039_346_656_037
    var previousWasCR = page.previousWasCR
    var count = 0
    for offset in 0..<page.byteCount {
      let byte = bytes[base + offset]
      // FNV-1a is a mutation check, not an authenticity check. Wrap is defined.
      checksum = (checksum ^ UInt64(byte)) &* 1_099_511_628_211
      if byte == 0x0d || (byte == 0x0a && !previousWasCR) {
        breaks[base + count] = UInt32(offset)
        count += 1
      }
      previousWasCR = byte == 0x0d
    }
    guard checksum == page.checksum && count == page.breakCount else { throw .fileChanged }
    slots[victim] = CachedFilePage(fileOffset: page.fileOffset, age: clock)
    statistics.loaded(bytes: page.byteCount, evicted: evicted)
    return victim
  }

  /// Owns an unpublished document until validation finishes. Each advance reads
  /// at most 64 pages / 4 MiB, with a 4 ms elapsed deadline checked between pages.
  /// A single syscall/page may exceed the deadline; disk latency is not bounded.
  /// Rope growth is bounded by maximumPages and stops before publication. A
  /// failed indexer can never publish; cancellation simply releases its owner.
  struct Indexer: ~Copyable, ~Sendable {
    static let maximumPagesPerBatch = 64
    static let maximumBytesPerBatch = 4_194_304
    private var document: PagedFileDocument
    private var previousWasCR = false
    private var unicode = FileUnicodeIndexState()
    private let content: FileContentPolicy
    private var failure: FileDocumentError?
    private(set) var indexedByteCount = 0
    private(set) var isComplete = false

    var byteCount: Int { document.byteCount }
    var indexedPageCount: Int { document.indexedPageCount }

    init(
      _ path: String, configuration: FileDocumentConfiguration = .init(), content: FileContentPolicy = .utf8
    ) throws(FileDocumentError) {
      try configuration.validate()
      let file = try OwnedDocumentFile.open(path)
      let identity = try file.identity()
      guard identity.byteCount <= configuration.maximumFileBytes else { throw .indexCapacityExceeded }
      document = PagedFileDocument(file: consume file, identity: identity, configuration: configuration)
      self.content = content
    }

    mutating func advance(maximumPages: Int = maximumPagesPerBatch) throws(FileDocumentError) {
      guard (1...Self.maximumPagesPerBatch).contains(maximumPages) else { throw .invalidConfiguration }
      if let failure { throw failure }
      guard !isComplete else { return }
      do throws(FileDocumentError) {
        try document.verifyUnchanged()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(4))
        let firstByte = indexedByteCount
        var pages = 0
        while indexedByteCount < byteCount && pages < maximumPages {
          let count = min(document.configuration.pageBytes, byteCount - indexedByteCount)
          if indexedByteCount - firstByte + count > Self.maximumBytesPerBatch { break }
          try indexPage(byteCount: count)
          pages += 1
          if clock.now >= deadline { break }
        }
        try document.verifyUnchanged()
        if indexedByteCount == byteCount {
          if let invalid = unicode.finish() {
            try recordInvalidUTF8(at: invalid)
          }
          assert(document.index.byteCount == byteCount)
          isComplete = true
        }
      } catch {
        failure = error
        throw error
      }
    }

    consuming func finish() -> PagedFileDocument {
      precondition(isComplete && failure == nil, "Only a validated index can be published")
      return consume document
    }

    private mutating func indexPage(byteCount: Int) throws(FileDocumentError) {
      do {
        // Cache slot zero doubles as initialization scratch, never residency.
        var storage = document.bytes.mutableSpan
        try document.file.readExactly(from: indexedByteCount, into: storage._mutatingExtracting(first: byteCount))
      }
      let startsAfterCR = previousWasCR
      let checkpoint = unicode.checkpoint
      assert(indexedByteCount - checkpoint.offset <= Glyph.maximumUTF8Bytes + 3)
      var breakCount = 0
      var checksum: UInt64 = 14_695_981_039_346_656_037
      var asciiStart = 0
      for local in 0..<byteCount {
        let byte = document.bytes[local]
        if byte >= 0x80 {
          document.isASCII = false
          if asciiStart < local {
            let failure = unicode.appendASCII(
              document.bytes.span.extracting(asciiStart..<local), at: indexedByteCount + asciiStart)
            if let failure { try recordInvalidUTF8(at: failure) }
          }
          if let invalid = unicode.append(byte, at: indexedByteCount + local) { try recordInvalidUTF8(at: invalid) }
          asciiStart = local + 1
        }
        checksum = (checksum ^ UInt64(byte)) &* 1_099_511_628_211
        if byte == 0x0d || (byte == 0x0a && !previousWasCR) { breakCount += 1 }
        previousWasCR = byte == 0x0d
      }
      if asciiStart < byteCount {
        let failure = unicode.appendASCII(
          document.bytes.span.extracting(asciiStart..<byteCount), at: indexedByteCount + asciiStart)
        if let failure { try recordInvalidUTF8(at: failure) }
      }
      try document.index.append(
        .init(
          fileOffset: indexedByteCount, byteCount: byteCount, breakCount: breakCount,
          previousWasCR: startsAfterCR, checksum: checksum, unicodeCheckpoint: checkpoint))
      indexedByteCount += byteCount
    }

    private mutating func recordInvalidUTF8(at offset: Int) throws(FileDocumentError) {
      if content == .utf8 { throw .invalidUTF8(byteOffset: offset) }
      if document.invalidUTF8ByteOffset == nil { document.invalidUTF8ByteOffset = offset }
    }
  }
}

// Module scope avoids a Swift 6.4.2 private generic-metadata emission bug when
// this noncopyable reader is initialized or destroyed from another source file.
struct CachedFilePage {
  var fileOffset = -1
  var age: UInt64 = 0
}

struct DocumentFileIdentity: Equatable {
  let device: DeviceID
  let inode: Inode
  let byteCount: Int
  let modificationSeconds: Int
  let modificationNanoseconds: Int
  let changeSeconds: Int
  let changeNanoseconds: Int
}

struct OwnedDocumentFile: ~Copyable {
  private let descriptor: FileDescriptor

  static func open(_ path: String) throws(FileDocumentError) -> Self {
    guard !path.utf8.contains(0) else { throw .invalidPath }
    do {
      // Preserve the OS path spelling, including trailing separators. FilePath
      // normalizes these, which could allow a regular file ending in "/".
      let descriptor = try path.withCString {
        try unsafe FileDescriptor.open(
          $0, .readOnly, options: [.closeOnExec, .nonBlocking], retryOnInterrupt: false)
      }
      return Self(descriptor: descriptor)
    } catch let error as Errno {
      throw .open(errno: error.rawValue)
    } catch {
      preconditionFailure("FileDescriptor.open only throws Errno")
    }
  }

  borrowing func identity() throws(FileDocumentError) -> DocumentFileIdentity {
    let status: Stat
    do { status = try Stat(descriptor, retryOnInterrupt: false) } catch { throw .inspect(errno: error.rawValue) }
    guard status.type == .regular else { throw .notRegularFile }
    guard status.size >= 0 && status.size <= Int.max else { throw .indexCapacityExceeded }
    return .init(
      device: status.deviceID, inode: status.inode,
      byteCount: Int(status.size), modificationSeconds: status.st_mtim.tv_sec,
      modificationNanoseconds: status.st_mtim.tv_nsec, changeSeconds: status.st_ctim.tv_sec,
      changeNanoseconds: status.st_ctim.tv_nsec)
  }

  borrowing func readExactly(
    from offset: Int, into buffer: consuming MutableSpan<UInt8>
  ) throws(FileDocumentError) {
    var buffer = consume buffer
    var done = 0
    var interruptions = 0
    while done < buffer.count {
      // Catch System's untyped error inside the buffer borrow. Passing a
      // concrete Result across that scope avoids propagating an erased error.
      let result: Result<Int, Errno> = buffer.withUnsafeMutableBufferPointer { storage in
        do {
          return .success(
            try unsafe descriptor.read(
              fromAbsoluteOffset: Int64(offset + done),
              into: UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(storage)[done...]),
              retryOnInterrupt: false))
        } catch let error as Errno {
          return .failure(error)
        } catch {
          preconditionFailure("FileDescriptor.read only throws Errno")
        }
      }
      switch result {
      case .success(let count):
        guard count > 0 else { throw .fileChanged }
        done += count
      case .failure(let error):
        if error == .interrupted && interruptions < 8 {
          interruptions += 1
          continue
        }
        throw .read(errno: error.rawValue)
      }
    }
  }

  deinit { try? descriptor.close() }
}
