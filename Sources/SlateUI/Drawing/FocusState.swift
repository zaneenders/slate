import BasicContainers

public enum FocusDirection: Equatable, Sendable {
  case left, right, up, down
}

public enum FocusVisibility: Equatable, Sendable {
  case visible, collapsed
}

/// Explicit links take precedence over spatial lookup. A missing link uses
/// geometry; an unavailable linked target stops movement without falling through.
public struct FocusNeighbors<ID: Hashable>: ~Sendable {
  public let left: ID?
  public let right: ID?
  public let up: ID?
  public let down: ID?

  public init(left: ID?, right: ID?, up: ID?, down: ID?) {
    self.left = left
    self.right = right
    self.up = up
    self.down = down
  }

  public static var automatic: Self { Self(left: nil, right: nil, up: nil, down: nil) }

  func target(in direction: FocusDirection) -> ID? {
    switch direction {
    case .left: left
    case .right: right
    case .up: up
    case .down: down
    }
  }
}

/// Fixed-capacity spatial focus from the last successful surface render.
/// Groups and targets share the capacity. Target IDs must be unique per frame.
/// Selection and input handling are
/// explicit: this owner never consumes keys or starts editing a control.
public final class FocusState<ID: Hashable>: ~Sendable {
  let storage: FocusRecords<ID>
  public var focusedID: ID? { storage.requestedID ?? storage.focusedID }
  public var capacity: Int { storage.capacity }
  /// Fixed record buffers, excluding class owners and storage referenced by IDs.
  public var storageBudgetBytes: Int { storage.storageBudgetBytes }

  public init(capacity: Int = 64, initial: ID? = nil) {
    storage = FocusRecords(capacity: capacity, initial: initial)
  }

  public func isFocused(_ id: ID) -> Bool { focusedID == id }
  public func bounds(for id: ID) -> Rect? {
    guard let index = storage.index(for: id) else { return nil }
    let bounds = storage.bounds(at: index)
    return bounds.isEmpty ? nil : bounds
  }

  /// Includes collapsed regions, which can receive focus through explicit links.
  public func contains(_ id: ID) -> Bool { storage.index(for: id) != nil }

  /// Sets the requested ID before layout, including when its pane was hidden.
  /// Bounds remain committed; the next layout replaces a missing target with
  /// the first visible target before painting. Empty layouts retain the request.
  public func requestFocus(_ id: ID) { storage.requestFocus(id) }

  /// Selects an eligible target from the committed layout. Returns true only
  /// when selection changes. Use initial to choose focus before the first frame.
  @discardableResult public func focus(_ id: ID) -> Bool { storage.focus(id) }

  /// Mouse selection uses the frontmost enabled target's clipped bounds.
  @discardableResult public func focus(column: Int, row: Int) -> Bool { storage.focus(column: column, row: row) }

  @discardableResult public func clear() -> Bool {
    let changed = storage.requestedID != nil || storage.focusedID != nil
    storage.requestedID = nil
    storage.focusedID = nil
    return changed
  }

  /// Searches inside the current group first, then its ancestors. Aligned
  /// regions precede diagonals; entering a group prefers an aligned target.
  /// A destination must extend past the source's edge in the requested direction;
  /// a smaller target contained within that axis is not a sideways neighbor.
  /// Leaving a group also checks the source and destination group rectangles:
  /// side-by-side groups require horizontal movement, stacked groups vertical.
  /// No wrapping. With no selection, chooses the first visible target.
  /// Work is bounded by capacity times layout depth; navigation allocates nothing.
  @discardableResult public func move(_ direction: FocusDirection) -> Bool { storage.move(direction) }
}

private struct FocusRecord<ID: Hashable> {
  let id: ID?
  let parent: Int
  let depth: Int
  let enabled: Bool
  let visibility: FocusVisibility
  let neighbors: FocusNeighbors<ID>
  var order = 0
  var bounds = Rect(width: 0, height: 0)
}

final class FocusRecords<ID: Hashable>: HitMapStorage, ~Sendable {
  let capacity: Int
  var focusedID: ID?
  var requestedID: ID?
  var stagingGroup = -1
  private var records: RigidArray<FocusRecord<ID>?>
  private var pending: RigidArray<FocusRecord<ID>?>
  private var count = 0
  private var pendingCount = 0

  init(capacity: Int, initial: ID?) {
    precondition((1...LayoutBudget.maximumNodeCapacity).contains(capacity))
    self.capacity = capacity
    focusedID = initial
    records = RigidArray(repeating: nil, count: capacity)
    pending = RigidArray(repeating: nil, count: capacity)
  }

  override var ownershipError: LayoutError { .focusStateInUse }
  var storageBudgetBytes: Int { 2 * capacity * MemoryLayout<FocusRecord<ID>?>.stride }
  func bounds(at index: Int) -> Rect { records[index]!.bounds }

  func append(
    _ id: ID?, enabled: Bool, visibility: FocusVisibility, neighbors: FocusNeighbors<ID>
  ) throws(LayoutError) -> Int {
    guard pendingCount < capacity else { throw .focusCapacityExceeded }
    let index = pendingCount
    let depth = stagingGroup < 0 ? 0 : pending[stagingGroup]!.depth + 1
    guard depth < LayoutLimits.maximumDepth else { throw .depthExceeded }
    pending[index] = FocusRecord(
      id: id, parent: stagingGroup, depth: depth, enabled: enabled, visibility: visibility, neighbors: neighbors)
    pendingCount += 1
    return index
  }

  override func setBounds(_ bounds: Rect, at index: Int) {
    pending[index]!.bounds = pending[index]!.visibility == .collapsed ? Rect(width: 0, height: 0) : bounds
  }

  override func enterRegion(at index: Int, order: Int) -> Int {
    pending[index]!.order = order
    let previous = stagingGroup
    if pending[index]!.id == nil { stagingGroup = index }
    return previous
  }

  override func leaveRegion(_ previous: Int) { stagingGroup = previous }

  override func prepareForPainting(in viewport: Rect) {
    guard let requestedID else { return }
    var fallback: ID?
    for index in 0..<pendingCount {
      let record = pending[index]!
      guard let id = record.id, record.enabled else { continue }
      let visible = record.visibility == .visible && !record.bounds.intersection(viewport).isEmpty
      if id == requestedID && (visible || record.visibility == .collapsed) {
        focusedID = id
        self.requestedID = nil
        return
      }
      if visible && fallback == nil { fallback = id }
    }
    if let fallback {
      focusedID = fallback
      self.requestedID = nil
    }
  }

  override func commit(in viewport: Rect) {
    for index in 0..<count { records[index] = nil }
    swap(&records, &pending)
    count = pendingCount
    pendingCount = 0
    stagingGroup = -1
    for index in 0..<count { records[index]!.bounds = records[index]!.bounds.intersection(viewport) }
    if let focusedID, self.index(for: focusedID) == nil { self.focusedID = nil }
  }

  override func discardPending() {
    for index in 0..<pendingCount { pending[index] = nil }
    pendingCount = 0
    stagingGroup = -1
    stagingFrame = nil
  }

  override func clear() {
    for index in 0..<count { records[index] = nil }
    count = 0
    focusedID = nil
    committedFrame = nil
  }

  func index(for id: ID) -> Int? {
    for index in (0..<count).reversed() where eligible(index) && records[index]!.id == id { return index }
    return nil
  }

  private func eligible(_ index: Int) -> Bool {
    let record = records[index]!
    return record.id != nil && record.enabled && (record.visibility == .collapsed || !record.bounds.isEmpty)
  }

  func focus(_ id: ID) -> Bool {
    guard index(for: id) != nil else { return false }
    requestedID = nil
    guard id != focusedID else { return false }
    focusedID = id
    return true
  }

  func focus(column: Int, row: Int) -> Bool {
    var best: Int?
    for index in (0..<count).reversed()
    where eligible(index) && records[index]!.visibility == .visible
      && records[index]!.bounds.contains(column: column, row: row)
    {
      if best == nil || records[index]!.order > records[best!]!.order { best = index }
    }
    guard let best else { return false }
    return focus(records[best]!.id!)
  }

  func requestFocus(_ id: ID) {
    requestedID = id
    focusedID = id
  }

  func move(_ direction: FocusDirection) -> Bool {
    requestedID = nil
    guard let focusedID, let current = index(for: focusedID) else {
      for index in 0..<count where eligible(index) && records[index]!.visibility == .visible {
        return focus(records[index]!.id!)
      }
      return false
    }
    if let target = records[current]!.neighbors.target(in: direction) { return focus(target) }
    let origin = records[current]!.bounds
    guard !origin.isEmpty else { return false }
    var best: Int?
    var bestRank: FocusRank?
    for candidate in 0..<count
    where eligible(candidate) && records[candidate]!.visibility == .visible && records[candidate]!.id != focusedID {
      guard let entry = FocusScore(origin: origin, candidate: records[candidate]!.bounds, direction: direction) else {
        continue
      }
      // Find the nearest shared group and the candidate's branch inside it.
      // Parent indices and depths make this a bounded ancestor walk.
      var sourceParent = records[current]!.parent
      var targetParent = records[candidate]!.parent
      var sourceBranch = current
      var branch = candidate
      var ascents = 0
      while sourceParent != targetParent {
        let sourceDepth = sourceParent < 0 ? -1 : records[sourceParent]!.depth
        let targetDepth = targetParent < 0 ? -1 : records[targetParent]!.depth
        if sourceDepth >= targetDepth {
          sourceBranch = sourceParent
          sourceParent = records[sourceParent]!.parent
          ascents += 1
        } else {
          branch = targetParent
          targetParent = records[targetParent]!.parent
        }
      }
      if sourceBranch != current || branch != candidate {
        // Choose a neighboring region before choosing a control inside it.
        // A child below the source does not make a side panel a Down neighbor.
        guard
          FocusScore(
            origin: records[sourceBranch]!.bounds, candidate: records[branch]!.bounds,
            direction: direction, crossingGroupBoundary: true) != nil
        else { continue }
      }
      let groupScore = FocusScore(origin: origin, candidate: records[branch]!.bounds, direction: direction) ?? entry
      let rank = FocusRank(ascents: ascents, branch: groupScore, entry: entry)
      if bestRank == nil || rank.precedes(bestRank!) {
        best = candidate
        bestRank = rank
      }
    }
    guard let best else { return false }
    return focus(records[best]!.id!)
  }
}

private struct FocusRank {
  let ascents: Int
  let branch: FocusScore
  let entry: FocusScore

  func precedes(_ other: Self) -> Bool {
    if ascents != other.ascents { return ascents < other.ascents }
    if branch != other.branch { return branch.precedes(other.branch) }
    return entry.precedes(other.entry, entering: true)
  }
}

private struct FocusScore: Equatable {
  let beam: Int
  let gap: Int
  let cross: Int
  let forward: Int

  init?(origin: Rect, candidate: Rect, direction: FocusDirection, crossingGroupBoundary: Bool = false) {
    guard !candidate.isEmpty else { return nil }
    let horizontal = direction == .left || direction == .right
    let sign = direction == .right || direction == .down ? 1 : -1
    let ax = origin.x + origin.right
    let ay = origin.y + origin.bottom
    let bx = candidate.x + candidate.right
    let by = candidate.y + candidate.bottom
    forward = sign * (horizontal ? bx - ax : by - ay)
    guard forward > 0 else { return nil }
    let overlap =
      horizontal
      ? min(origin.bottom, candidate.bottom) - max(origin.y, candidate.y)
      : min(origin.right, candidate.right) - max(origin.x, candidate.x)
    if crossingGroupBoundary && overlap <= 0 {
      let alongDirection =
        horizontal
        ? min(origin.right, candidate.right) - max(origin.x, candidate.x)
        : min(origin.bottom, candidate.bottom) - max(origin.y, candidate.y)
      guard alongDirection <= 0 else { return nil }
    }
    beam = overlap > 0 ? 0 : 1
    cross = horizontal ? abs(by - ay) : abs(bx - ax)
    switch direction {
    case .left:
      guard candidate.x < origin.x else { return nil }
      gap = max(0, origin.x - candidate.right)
    case .right:
      guard candidate.right > origin.right else { return nil }
      gap = max(0, candidate.x - origin.right)
    case .up:
      guard candidate.y < origin.y else { return nil }
      gap = max(0, origin.y - candidate.bottom)
    case .down:
      guard candidate.bottom > origin.bottom else { return nil }
      gap = max(0, candidate.y - origin.bottom)
    }
  }

  func precedes(_ other: Self, entering: Bool = false) -> Bool {
    if entering { return (beam, cross, gap, forward) < (other.beam, other.cross, other.gap, other.forward) }
    return (beam, gap, cross, forward) < (other.beam, other.gap, other.cross, other.forward)
  }
}
