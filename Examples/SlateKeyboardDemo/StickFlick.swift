/// A bounded gesture recognizer, separate from navigation key repeat. It needs
/// neutral input after creation/reset. Holding a stick never emits characters.
struct StickFlick {
  private(set) var active: Int?
  private var armed = false
  let eightWay: Bool

  mutating func update(x: Float, y: Float) -> Int? {
    guard x.isFinite && y.isFinite else {
      reset()
      return nil
    }
    let x = max(-1, min(1, x))
    let y = max(-1, min(1, y))
    let magnitude = max(abs(x), abs(y))
    let radiusSquared = x * x + y * y
    if !armed {
      if radiusSquared <= 0.35 * 0.35 { armed = true }
      return nil
    }
    if radiusSquared <= 0.35 * 0.35 {
      let committed = active
      active = nil
      return committed
    }
    guard radiusSquared >= 0.55 * 0.55 else { return nil }
    let sector: Int
    if !eightWay || abs(x) > abs(y) * 2.414_214 || abs(y) > abs(x) * 2.414_214 {
      sector = abs(y) >= abs(x) ? (y >= 0 ? 0 : 4) : (x >= 0 ? 2 : 6)
    } else {
      sector = y >= 0 ? (x >= 0 ? 1 : 7) : (x >= 0 ? 3 : 5)
    }
    if let old = active, old != sector {
      // Keep the current sector near angular boundaries. Dot products use
      // normalized direction vectors and a magnitude-relative hysteresis band.
      if projection(sector, x: x, y: y) > projection(old, x: x, y: y) + magnitude * 0.12 { active = sector }
    } else {
      active = sector
    }
    return nil
  }
  mutating func reset() {
    active = nil
    armed = false
  }
  private func projection(_ sector: Int, x: Float, y: Float) -> Float {
    switch sector {
    case 0: y
    case 1: (x + y) * 0.707_107
    case 2: x
    case 3: (x - y) * 0.707_107
    case 4: -y
    case 5: (-x - y) * 0.707_107
    case 6: -x
    default: (-x + y) * 0.707_107
    }
  }
}

enum KeyboardLetters {
  static let groups = ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]
  static func letter(group: Int, sector: Int) -> UInt8? {
    guard (0..<8).contains(group), (0..<8).contains(sector), sector % 2 == 0 else { return nil }
    let text = groups[group].utf8Span
    let index = sector / 2
    return index < text.count ? text.span[index] : nil
  }
}
