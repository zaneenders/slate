import BasicContainers

public enum NavigationRoute<ScopeID: Hashable, TargetID: Hashable>: ~Sendable {
  /// Only this scope receives the action. Back can reach an empty dialog.
  case action(scope: ScopeID, target: TargetID?, intent: NavigationIntent)
  case focusChanged(scope: ScopeID, target: TargetID)
  /// A focus edge or missing target consumes navigation without parent fallback.
  case blocked(scope: ScopeID)
}

public enum NavigationInputResult<ScopeID: Hashable, TargetID: Hashable>: ~Sendable {
  /// Deliver the original key to this scope's control (typing, editing, or a
  /// local shortcut). This is an explicit owner, not permission to bubble input.
  case input(scope: ScopeID, target: TargetID?)
  case consumed
  case routed(NavigationRoute<ScopeID, TargetID>)
}

private struct NavigationScope<ScopeID: Hashable, TargetID: Hashable>: ~Sendable {
  let id: ScopeID
  let focus: FocusState<TargetID>
  let returnTarget: TargetID?
}

/// A bounded stack of input owners. Each scope has its own registered targets;
/// movement, clicks and activation cannot fall through to a covered scope.
/// The caller applies content actions and closes UI before popping its scope.
public final class NavigationRouter<ScopeID: Hashable, TargetID: Hashable>: ~Sendable {
  public static var maximumScopeCapacity: Int { 32 }
  public let capacity: Int
  public private(set) var count = 1
  private var scopes: RigidArray<NavigationScope<ScopeID, TargetID>?>
  private var keys = NavigationKeymap()

  public var activeScope: ScopeID { scopes[count - 1]!.id }
  public var focusedID: TargetID? { scopes[count - 1]!.focus.focusedID }
  public var windowPending: Bool { keys.windowPending }
  public var storageBudgetBytes: Int {
    capacity * MemoryLayout<NavigationScope<ScopeID, TargetID>?>.stride
  }

  public init(root: ScopeID, focus: FocusState<TargetID>, capacity: Int) {
    precondition((1...Self.maximumScopeCapacity).contains(capacity))
    self.capacity = capacity
    scopes = RigidArray(repeating: nil, count: capacity)
    scopes[0] = NavigationScope(id: root, focus: focus, returnTarget: nil)
  }

  /// Full stacks and duplicate scope/focus owners reject without changing input
  /// ownership. Construct focus owners at startup and reuse them when reopening.
  @discardableResult public func push(_ scope: ScopeID, focus: FocusState<TargetID>) -> Bool {
    guard count < capacity else { return false }
    for index in 0..<count where scopes[index]!.id == scope || scopes[index]!.focus === focus { return false }
    let previous = focusedID
    scopes[count] = NavigationScope(id: scope, focus: focus, returnTarget: previous)
    count += 1
    keys.cancel()
    return true
  }

  /// The root never pops. Restoration waits for layout if the parent was hidden;
  /// a removed return target falls back on the next nonempty registration.
  @discardableResult public func pop() -> Bool {
    guard count > 1 else { return false }
    let target = scopes[count - 1]!.returnTarget
    count -= 1
    scopes[count] = nil
    keys.cancel()
    if let target { scopes[count - 1]!.focus.requestFocus(target) }
    return true
  }

  public func cancelPendingKeys() { keys.cancel() }

  @discardableResult public func focus(_ target: TargetID) -> Bool {
    keys.cancel()
    return scopes[count - 1]!.focus.focus(target)
  }

  @discardableResult public func focus(column: Int, row: Int) -> Bool {
    keys.cancel()
    return scopes[count - 1]!.focus.focus(column: column, row: row)
  }

  public func route(
    _ key: InputKey, modifiers: KeyModifiers, mode: NavigationMode
  ) -> NavigationInputResult<ScopeID, TargetID> {
    switch keys.resolve(key, modifiers: modifiers, mode: mode) {
    case .unhandled: return .input(scope: activeScope, target: focusedID)
    case .consumed: return .consumed
    case .intent(let intent): return .routed(route(intent))
    }
  }

  public func route(_ intent: NavigationIntent) -> NavigationRoute<ScopeID, TargetID> {
    keys.cancel()
    let scope = scopes[count - 1]!
    switch intent {
    case .focus(let direction):
      guard scope.focus.move(direction), let target = scope.focus.focusedID else { return .blocked(scope: scope.id) }
      return .focusChanged(scope: scope.id, target: target)
    case .move, .activate:
      guard let target = scope.focus.focusedID, scope.focus.contains(target) else { return .blocked(scope: scope.id) }
      return .action(scope: scope.id, target: target, intent: intent)
    case .back: return .action(scope: scope.id, target: scope.focus.focusedID, intent: intent)
    }
  }
}
