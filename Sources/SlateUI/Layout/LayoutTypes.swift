/// Roots-style sizing, measured in whole terminal cells.
public enum LayoutSize: Equatable, Sendable {
  case fit
  case fill
  case fixed(Int)

  func measured(_ content: Int) -> Int {
    if case .fixed(let value) = self { return value }
    return content
  }

  func resolved(_ content: Int, available: Int) -> Int {
    switch self {
    case .fit: return min(content, available)
    case .fill: return available
    case .fixed(let value): return min(value, available)
    }
  }
}

public enum Alignment: Sendable {
  case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

  func offset(available: Int, content: Int, horizontal: Bool) -> Int {
    let remainder = max(0, available - content)
    switch self {
    case .topLeading: return 0
    case .top: return horizontal ? remainder / 2 : 0
    case .topTrailing: return horizontal ? remainder : 0
    case .center: return remainder / 2
    case .leading: return horizontal ? 0 : remainder / 2
    case .trailing: return horizontal ? remainder : remainder / 2
    case .bottomLeading: return horizontal ? 0 : remainder
    case .bottom: return horizontal ? remainder / 2 : remainder
    case .bottomTrailing: return remainder
    }
  }
}

public enum LayoutLimits: Sendable {
  public static let maximumDepth = 32
  /// Bounds the Swift call stack, including custom bodies and builder pairs.
  public static let maximumBuildDepth = 128
  public static let maximumTextScalars = 4_096
}

/// Fixed startup storage and per-frame traversal limits. The internal root uses
/// one node. Visits include primitives, custom bodies, builder pairs, and empty
/// blocks. Arbitrary work performed inside application callbacks remains caller-owned.
/// Invalid budgets are rejected by Surface/Screen initialization before allocation.
public struct LayoutBudget: Equatable, Sendable {
  // On the pinned 64-bit toolchain, the two tables use 192 bytes per node:
  // 768 KiB by default and 24 MiB at this maximum, excluding cells and owners.
  public static let maximumNodeCapacity = 131_072
  public static let maximumBlockVisitsLimit = 1_048_576

  public let nodeCapacity: Int
  public let maximumBlockVisits: Int

  public init(nodeCapacity: Int = 4_096, maximumBlockVisits: Int = 16_384) {
    self.nodeCapacity = nodeCapacity
    self.maximumBlockVisits = maximumBlockVisits
  }

  var isValid: Bool {
    (1...Self.maximumNodeCapacity).contains(nodeCapacity)
      && (1...Self.maximumBlockVisitsLimit).contains(maximumBlockVisits)
  }
}

public enum LayoutError: Error, Equatable, Sendable {
  case depthExceeded
  case buildDepthExceeded
  case nodeCapacityExceeded
  case blockVisitLimitExceeded
  case textTooLong
}
