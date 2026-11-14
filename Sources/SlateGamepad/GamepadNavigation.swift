public import SlateUI

/// Physical positions, independent of the controller's printed button labels.
public struct GamepadButtons: OptionSet, Equatable, Sendable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }
  public static let up = Self(rawValue: 1 << 0)
  public static let down = Self(rawValue: 1 << 1)
  public static let left = Self(rawValue: 1 << 2)
  public static let right = Self(rawValue: 1 << 3)
  /// Cross on PlayStation, A on Xbox.
  public static let south = Self(rawValue: 1 << 4)
  /// Circle on PlayStation, B on Xbox.
  public static let east = Self(rawValue: 1 << 5)
  /// Square on PlayStation, X on Xbox.
  public static let west = Self(rawValue: 1 << 6)
  /// Triangle on PlayStation, Y on Xbox.
  public static let north = Self(rawValue: 1 << 7)
  public static let leftShoulder = Self(rawValue: 1 << 8)
  public static let rightShoulder = Self(rawValue: 1 << 9)
  static let directions: Self = [.up, .down, .left, .right]
}

/// A sampled state. Stick axes are -1...1, with positive Y pointing up.
/// A disconnected sample clears all held buttons and repeat state.
public struct GamepadState: Equatable, Sendable {
  public var connected: Bool
  public var buttons: GamepadButtons
  public var leftX: Float
  public var leftY: Float
  public var rightX: Float
  public var rightY: Float

  public init(
    connected: Bool = false, buttons: GamepadButtons = [], leftX: Float = 0, leftY: Float = 0,
    rightX: Float = 0, rightY: Float = 0
  ) {
    self.connected = connected
    self.buttons = buttons
    self.leftX = leftX
    self.leftY = leftY
    self.rightX = rightX
    self.rightY = rightY
  }
}

public enum GamepadAction: Equatable, Sendable {
  case move(FocusDirection)
  case activate
  case back
  case pause
}

/// At most one movement and two button edges per sample. No queue or growth.
public struct GamepadActions: Sendable {
  private var storage: InlineArray<3, GamepadAction?> = .init(repeating: nil)
  public private(set) var count = 0
  public subscript(index: Int) -> GamepadAction {
    precondition(index >= 0 && index < count)
    return storage[index]!
  }
  fileprivate mutating func append(_ action: GamepadAction) {
    // The translator emits at most three actions; callers cannot insert.
    precondition(count < 3)
    storage[count] = action
    count += 1
  }
}

/// Allocation-free translation of sampled input. Poll at least every 16 ms.
/// Initial connection/reconnection requires neutral controls before activation.
/// D-pad takes precedence; diagonals choose the stronger axis (vertical on ties).
public struct GamepadNavigation: Sendable {
  private var armed = false
  private var previousButtons: GamepadButtons = []
  private var heldDirection: FocusDirection?
  private var repeatOrigin: ContinuousClock.Instant?
  private var isRepeating = false
  private var stickDirection: FocusDirection?

  public init() {}

  public mutating func update(_ state: GamepadState, at now: ContinuousClock.Instant) -> GamepadActions {
    var actions = GamepadActions()
    guard state.connected else {
      self = Self()
      return actions
    }
    let direction = direction(for: state)
    guard armed else {
      armed = state.buttons.isEmpty && direction == nil
      return actions
    }
    let pressed = state.buttons.subtracting(previousButtons)
    previousButtons = state.buttons
    // Back wins over activation when both buttons arrive in the same sample.
    if pressed.contains(.east) { actions.append(.back) } else if pressed.contains(.south) { actions.append(.activate) }
    if pressed.contains(.west) { actions.append(.pause) }
    if direction != heldDirection {
      heldDirection = direction
      repeatOrigin = direction == nil ? nil : now
      isRepeating = false
      if let direction { actions.append(.move(direction)) }
    } else if let direction, let origin = repeatOrigin,
      origin.duration(to: now) >= (isRepeating ? .milliseconds(100) : .milliseconds(350))
    {
      actions.append(.move(direction))
      repeatOrigin = now
      isRepeating = true
    }
    return actions
  }

  private mutating func direction(for state: GamepadState) -> FocusDirection? {
    let dpad = state.buttons.intersection(.directions)
    if !dpad.isEmpty {
      stickDirection = nil
      if dpad.contains(.up) != dpad.contains(.down) { return dpad.contains(.up) ? .up : .down }
      if dpad.contains(.left) != dpad.contains(.right) { return dpad.contains(.left) ? .left : .right }
      return nil
    }
    guard state.leftX.isFinite && state.leftY.isFinite else {
      stickDirection = nil
      return nil
    }
    let x = max(-1, min(1, state.leftX))
    let y = max(-1, min(1, state.leftY))
    let threshold: Float = stickDirection == nil ? 0.55 : 0.35
    guard max(abs(x), abs(y)) >= threshold else {
      stickDirection = nil
      return nil
    }
    stickDirection = abs(y) >= abs(x) ? (y >= 0 ? .up : .down) : (x >= 0 ? .right : .left)
    return stickDirection
  }
}
