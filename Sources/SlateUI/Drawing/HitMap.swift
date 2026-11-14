import BasicContainers

/// A hit in surface coordinates, with a position relative to the target's bounds.
/// Local coordinates can be negative when routing a captured drag.
public struct Hit<ID: Hashable>: ~Sendable {
  public let id: ID
  public let bounds: Rect
  public let clippedBounds: Rect
  public let column: Int
  public let row: Int
  package let identity: UInt64
  package let viewportRevision: UInt64
  package let source: HitMap<ID>
}

private struct HitRecord<ID: Hashable> {
  var id: ID?
  var bounds = Rect(width: 0, height: 0)
  var identity: UInt64 = 0
}

/// Startup-owned, fixed-capacity hit regions from the last successful surface render.
/// Each map belongs to one surface at a time. Untagged content passes through; regions are
/// tested front to back, with children taking precedence over enclosing targets.
/// Rendering replaces the entire snapshot, including when every target is hidden.
public final class HitMap<ID: Hashable>: ~Sendable {
  let storage: HitMapRecords<ID>
  public var capacity: Int { storage.capacity }
  public var count: Int { storage.count }

  /// Capacity counts targets and mouse blockers. Exhaustion rejects the frame.
  public init(capacity: Int = 64) { storage = HitMapRecords(capacity: capacity) }

  /// Fixed element storage, excluding the class owners, allocator metadata, and
  /// storage referenced by caller-owned IDs.
  public var storageBudgetBytes: Int { storage.storageBudgetBytes }

  public func hitTest(column: Int, row: Int) -> Hit<ID>? {
    storage.hitTest(column: column, row: row, source: self)
  }

  /// Bounds before clipping, or nil for an absent/empty target. IDs should be
  /// unique; repeated IDs resolve to their frontmost registered region.
  public func bounds(for id: ID) -> Rect? { storage.bounds(for: id) }

  package func capturedHit(_ original: Hit<ID>, column: Int, row: Int) -> Hit<ID>? {
    guard original.source === self else { return nil }
    return storage.capturedHit(original, column: column, row: row)
  }
}

/// Concrete owner references keep the frame lists to one word per entry. Only
/// record operations dispatch to ID-specific storage; frame ownership is shared.
/// Instances are always HitMapRecords, allocated once by their public map.
@usableFromInline class HitMapStorage: ~Sendable {
  final var committedFrame: ObjectIdentifier?
  final var stagingFrame: ObjectIdentifier?
  func setBounds(_ bounds: Rect, at index: Int) { preconditionFailure("Abstract hit-map storage") }
  func commit(in viewport: Rect) { preconditionFailure("Abstract hit-map storage") }
  func discardPending() { preconditionFailure("Abstract hit-map storage") }
  func clear() { preconditionFailure("Abstract hit-map storage") }
}

final class HitMapRecords<ID: Hashable>: HitMapStorage, ~Sendable {
  let capacity: Int
  private(set) var count = 0
  private var records: RigidArray<HitRecord<ID>?>
  private var pending: RigidArray<HitRecord<ID>?>
  private var indices: RigidArray<Int>
  private var pendingCount = 0
  private var viewport = Rect(width: 0, height: 0)
  private var viewportRevision: UInt64 = 0
  private var nextIdentity: UInt64 = 0

  /// Capacity counts targets and mouse blockers. Exhaustion rejects the frame.
  init(capacity: Int) {
    precondition((1...LayoutBudget.maximumNodeCapacity).contains(capacity))
    self.capacity = capacity
    records = RigidArray(repeating: nil, count: capacity)
    pending = RigidArray(repeating: nil, count: capacity)
    var slots = 2
    while slots < capacity * 2 { slots *= 2 }
    indices = RigidArray(repeating: -1, count: slots)
  }

  /// Fixed element storage, excluding the class owner, allocator metadata, and
  /// storage referenced by caller-owned IDs.
  var storageBudgetBytes: Int {
    2 * capacity * MemoryLayout<HitRecord<ID>?>.stride
      + indices.count * MemoryLayout<Int>.stride
  }

  func hitTest(column: Int, row: Int, source: HitMap<ID>) -> Hit<ID>? {
    guard viewport.contains(column: column, row: row) else { return nil }
    for index in (0..<count).reversed() {
      let record = records[index]!
      guard record.bounds.contains(column: column, row: row) else { continue }
      // A nil ID is an explicit blocker for the remainder of this map.
      guard let id = record.id else { return nil }
      return hit(record, id: id, column: column, row: row, source: source)
    }
    return nil
  }

  /// Bounds before clipping, or nil for an absent/empty target. IDs should be
  /// unique; repeated IDs resolve to their frontmost registered region.
  func bounds(for id: ID) -> Rect? {
    guard let index = index(for: id), !records[index]!.bounds.intersection(viewport).isEmpty else { return nil }
    return records[index]!.bounds
  }

  func capturedHit(_ original: Hit<ID>, column: Int, row: Int) -> Hit<ID>? {
    guard original.viewportRevision == viewportRevision,
      let index = index(for: original.id),
      records[index]!.identity == original.identity,
      !records[index]!.bounds.intersection(viewport).isEmpty
    else { return nil }
    return hit(records[index]!, id: original.id, column: column, row: row, source: original.source)
  }

  private func hit(_ record: HitRecord<ID>, id: ID, column: Int, row: Int, source: HitMap<ID>) -> Hit<ID> {
    Hit(
      id: id, bounds: record.bounds, clippedBounds: record.bounds.intersection(viewport),
      column: column - record.bounds.x, row: row - record.bounds.y,
      identity: record.identity, viewportRevision: viewportRevision, source: source)
  }

  private func index(for id: ID) -> Int? {
    var slot = Int(UInt(bitPattern: id.hashValue) & UInt(indices.count - 1))
    while indices[slot] >= 0 {
      let index = indices[slot]
      if records[index]!.id == id { return index }
      slot = (slot + 1) & (indices.count - 1)
    }
    return nil
  }

  func append(_ id: ID?) throws(LayoutError) -> Int {
    guard pendingCount < capacity else { throw .hitRegionCapacityExceeded }
    let index = pendingCount
    pending[index] = HitRecord(id: id)
    pendingCount += 1
    return index
  }

  override func setBounds(_ bounds: Rect, at index: Int) { pending[index]!.bounds = bounds }

  override func commit(in viewport: Rect) {
    if self.viewport != viewport { viewportRevision &+= 1 }
    self.viewport = viewport
    // Resolve stable identities before replacing the old lookup table. This
    // preserves capture when targets move or reorder, and expires removed IDs.
    for index in 0..<pendingCount {
      if let id = pending[index]!.id, let previous = self.index(for: id),
        !records[previous]!.bounds.intersection(viewport).isEmpty
      {
        pending[index]!.identity = records[previous]!.identity
      } else {
        nextIdentity &+= 1
        pending[index]!.identity = nextIdentity
      }
    }
    for index in 0..<count { records[index] = nil }
    swap(&records, &pending)
    count = pendingCount
    pendingCount = 0
    for slot in 0..<indices.count { indices[slot] = -1 }
    for index in 0..<count {
      guard let id = records[index]!.id else { continue }
      var slot = Int(UInt(bitPattern: id.hashValue) & UInt(indices.count - 1))
      while indices[slot] >= 0 && records[indices[slot]]!.id != id {
        slot = (slot + 1) & (indices.count - 1)
      }
      indices[slot] = index
    }
  }

  override func discardPending() {
    for index in 0..<pendingCount { pending[index] = nil }
    pendingCount = 0
    stagingFrame = nil
  }

  override func clear() {
    for index in 0..<count { records[index] = nil }
    for slot in 0..<indices.count { indices[slot] = -1 }
    count = 0
    committedFrame = nil
  }
}

/// Two fixed lists let a rejected frame leave every previously committed map
/// untouched, even when it introduces new maps or omits all old regions.
final class HitMapFrame: ~Sendable {
  private var committed: RigidArray<HitMapStorage?>
  private var pending: RigidArray<HitMapStorage?>
  private var committedCount = 0
  private var pendingCount = 0

  init(capacity: Int) {
    committed = RigidArray(repeating: nil, count: capacity)
    pending = RigidArray(repeating: nil, count: capacity)
  }

  var storageBudgetBytes: Int {
    2 * committed.count * MemoryLayout<HitMapStorage?>.stride
  }

  func register(_ map: HitMapStorage) throws(LayoutError) {
    let owner = ObjectIdentifier(self)
    guard map.committedFrame == nil || map.committedFrame == owner,
      map.stagingFrame == nil || map.stagingFrame == owner
    else { throw .hitMapInUse }
    if map.stagingFrame == owner { return }
    precondition(pendingCount < pending.count)
    pending[pendingCount] = map
    pendingCount += 1
    map.stagingFrame = owner
  }

  func commit(in viewport: Rect) {
    for index in 0..<committedCount {
      let map = committed[index]!
      if map.stagingFrame != ObjectIdentifier(self) { map.clear() }
      committed[index] = nil
    }
    for index in 0..<pendingCount {
      let map = pending[index]!
      map.commit(in: viewport)
      map.committedFrame = ObjectIdentifier(self)
      map.stagingFrame = nil
    }
    swap(&committed, &pending)
    committedCount = pendingCount
    pendingCount = 0
  }

  func discardPending() {
    for index in 0..<pendingCount {
      pending[index]!.discardPending()
      pending[index] = nil
    }
    pendingCount = 0
  }

  deinit {
    discardPending()
    for index in 0..<committedCount { committed[index]!.clear() }
  }
}
