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
  case topLeading, center, leading, trailing, bottomTrailing

  func offset(available: Int, content: Int, horizontal: Bool) -> Int {
    let remainder = max(0, available - content)
    switch self {
    case .topLeading: return 0
    case .center: return remainder / 2
    case .leading: return horizontal ? 0 : remainder / 2
    case .trailing: return horizontal ? remainder : remainder / 2
    case .bottomTrailing: return remainder
    }
  }
}

public enum LayoutLimits: Sendable {
  public static let maximumNodes = 512
  public static let maximumDepth = 32
  public static let maximumTextScalars = 4_096
}

public enum LayoutError: Error, Equatable, Sendable {
  case nodeCapacityExceeded
  case depthExceeded
  case textTooLong
}
