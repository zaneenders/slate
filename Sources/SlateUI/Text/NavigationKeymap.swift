public enum NavigationIntent: Equatable, Sendable {
  case move(FocusDirection)
  case focus(FocusDirection)
  case activate
  case back
}

public enum NavigationMode: Equatable, Sendable {
  case normal, insert
}

public enum NavigationKeyResult: Equatable, Sendable {
  case unhandled
  case consumed
  case intent(NavigationIntent)
}

/// Opt-in Vim navigation. Unmodified movement belongs to content; Ctrl movement
/// belongs to pane focus. Insert passes through typing and editing shortcuts.
/// Ctrl-W then hjkl provides the same focus intents on legacy terminals.
public struct NavigationKeymap: Sendable {
  public private(set) var windowPending = false

  public init() {}

  public mutating func cancel() { windowPending = false }

  public mutating func resolve(
    _ originalKey: InputKey, modifiers originalModifiers: KeyModifiers, mode: NavigationMode
  ) -> NavigationKeyResult {
    var key = originalKey
    var modifiers = originalModifiers.withoutLocks
    if modifiers.contains(.control), case .character(let scalar) = key {
      let value = scalar.value
      let lower = (65...90).contains(value) ? value + 32 : value
      if (97...122).contains(lower), let control = ControlKey(rawValue: UInt8(lower - 96)) {
        key = .control(control)
      }
    }
    if case .control = key { modifiers.remove(.control) }
    if mode == .insert {
      windowPending = false
      return key == .escape && modifiers.isEmpty ? .intent(.back) : .unhandled
    }
    if windowPending {
      windowPending = false
      guard modifiers.isEmpty else { return .consumed }
      if let direction = direction(for: key) { return .intent(.focus(direction)) }
      if key == .backspace { return .intent(.focus(.left)) }
      return .consumed
    }
    guard modifiers.isEmpty else { return .unhandled }
    switch key {
    case .control(.h): return .intent(.focus(.left))
    case .control(.j): return .intent(.focus(.down))
    case .control(.k): return .intent(.focus(.up))
    case .control(.l): return .intent(.focus(.right))
    case .control(.w):
      windowPending = true
      return .consumed
    case .enter: return .intent(.activate)
    case .escape: return .intent(.back)
    default:
      if let direction = direction(for: key) { return .intent(.move(direction)) }
      return .unhandled
    }
  }

  private func direction(for key: InputKey) -> FocusDirection? {
    switch key {
    case .character("h"), .left, .control(.h): .left
    case .character("j"), .down, .control(.j): .down
    case .character("k"), .up, .control(.k): .up
    case .character("l"), .right, .control(.l): .right
    default: nil
    }
  }
}
