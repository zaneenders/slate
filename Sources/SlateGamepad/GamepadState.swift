public struct GamepadFeatures: OptionSet, Equatable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let rightStick = Self(rawValue: 1)
  public static let touchPositions = Self(rawValue: 2)
  /// The backend can distinguish a finger at the center from no contact.
  public static let touchContacts = Self(rawValue: 4)
}

/// Touch coordinates use -1...1, positive Y up. `isTouching == nil` means
/// contact state is unavailable; coordinates alone must never imply contact.
public struct GamepadTouch: Equatable, Sendable {
  public var x: Float
  public var y: Float
  public var isTouching: Bool?
  public init(x: Float = 0, y: Float = 0, isTouching: Bool? = nil) {
    self.x = x
    self.y = y
    self.isTouching = isTouching
  }
}

/// A fixed-size snapshot. Sticks use -1...1, positive Y up; triggers use 0...1.
/// `supportedButtons` distinguishes absent controls from released controls.
public struct GamepadState: Equatable, Sendable {
  public var connected: Bool
  public var buttons: GamepadButtons
  public var leftX: Float
  public var leftY: Float
  public var rightX: Float
  public var rightY: Float
  public var leftTrigger: Float
  public var rightTrigger: Float
  public var supportedButtons: GamepadButtons
  public var features: GamepadFeatures
  public var primaryTouch: GamepadTouch
  public var secondaryTouch: GamepadTouch

  public init(
    connected: Bool = false, buttons: GamepadButtons = [], leftX: Float = 0, leftY: Float = 0,
    rightX: Float = 0, rightY: Float = 0, leftTrigger: Float = 0, rightTrigger: Float = 0,
    supportedButtons: GamepadButtons = .standard, features: GamepadFeatures = .rightStick,
    primaryTouch: GamepadTouch = .init(), secondaryTouch: GamepadTouch = .init()
  ) {
    self.connected = connected
    self.buttons = buttons
    self.leftX = leftX
    self.leftY = leftY
    self.rightX = rightX
    self.rightY = rightY
    self.leftTrigger = leftTrigger
    self.rightTrigger = rightTrigger
    self.supportedButtons = connected ? supportedButtons : []
    self.features = connected ? features : []
    self.primaryTouch = primaryTouch
    self.secondaryTouch = secondaryTouch
  }

  public var isNeutral: Bool {
    connected && buttons.isEmpty && leftX.isFinite && leftY.isFinite && rightX.isFinite && rightY.isFinite
      && leftTrigger.isFinite && rightTrigger.isFinite
      && leftX * leftX + leftY * leftY <= 0.35 * 0.35
      && rightX * rightX + rightY * rightY <= 0.35 * 0.35
      && (0...0.1).contains(leftTrigger) && (0...0.1).contains(rightTrigger)
      && primaryTouch.isTouching != true && secondaryTouch.isTouching != true
  }
}

/// Shared trigger thresholds keep macOS/Linux button edges consistent. Native
/// digital trigger buttons are promoted to 0/1 by their backend before this step.
struct GamepadTriggerLatch {
  private var held: GamepadButtons = []
  mutating func apply(to state: inout GamepadState) {
    let triggers: GamepadButtons = [.leftTrigger, .rightTrigger]
    state.buttons.subtract(triggers)
    state.leftTrigger = normalized(state.leftTrigger)
    state.rightTrigger = normalized(state.rightTrigger)
    update(.leftTrigger, value: state.leftTrigger)
    update(.rightTrigger, value: state.rightTrigger)
    state.buttons.formUnion(held)
  }
  private mutating func update(_ button: GamepadButtons, value: Float) {
    if value >= (held.contains(button) ? 0.45 : 0.55) { held.insert(button) } else { held.remove(button) }
  }
  private func normalized(_ value: Float) -> Float { value.isFinite ? max(0, min(1, value)) : 0 }
}
