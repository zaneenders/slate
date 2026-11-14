#if os(Linux)
import CLinuxGamepad
import SystemPackage

struct PlatformGamepad: ~Copyable {
  private var descriptor: FileDescriptor?
  private var touchpad: FileDescriptor?
  private var capabilities = slate_gamepad_capabilities()
  private var identity = slate_gamepad_identity()
  private var hasIdentity = false
  private var lastDiscovery: ContinuousClock.Instant?
  private var lastTouchDiscovery: ContinuousClock.Instant?
  private var triggers = GamepadTriggerLatch()
  private(set) var status = GamepadStatus.disconnected

  mutating func sample(at now: ContinuousClock.Instant) -> GamepadState {
    if descriptor == nil {
      guard lastDiscovery == nil || lastDiscovery!.duration(to: now) >= .seconds(1) else { return .init() }
      lastDiscovery = now
      discover()
    }
    guard let descriptor else { return .init() }
    var raw = slate_gamepad_state()
    let result = unsafe slate_gamepad_read_state(descriptor.rawValue, capabilities.axes, &raw)
    guard result == 0 else {
      try? descriptor.close()
      self.descriptor = nil
      if let touchpad {
        try? touchpad.close()
        self.touchpad = nil
      }
      triggers = .init()
      hasIdentity = false
      status = result == -Errno.operationNotSupportedByDevice.rawValue ? .disconnected : .unavailable(errno: -result)
      return .init()
    }
    status = .connected
    var state = stateFromLinux(raw, capabilities: capabilities)
    triggers.apply(to: &state)
    if touchpad == nil && hasIdentity,
      lastTouchDiscovery == nil || lastTouchDiscovery!.duration(to: now) >= .seconds(1)
    {
      lastTouchDiscovery = now
      discoverTouchpad()
    }
    if let touchpad {
      var rawTouch = slate_gamepad_touch_state()
      if unsafe slate_gamepad_read_touchpad(touchpad.rawValue, &rawTouch) == 0 {
        state.supportedButtons.insert(.touchpad)
        state.features.formUnion([.touchPositions, .touchContacts])
        if rawTouch.pressed != 0 { state.buttons.insert(.touchpad) }
        state.primaryTouch = linuxTouch(rawTouch, secondary: false)
        state.secondaryTouch = linuxTouch(rawTouch, secondary: true)
      } else {
        // A missing auxiliary node must not disconnect a working gamepad.
        try? touchpad.close()
        self.touchpad = nil
      }
    }
    return state
  }

  private mutating func discover() {
    status = .disconnected
    for index in 0..<64 {
      guard let candidate = openCandidate(index, reportErrors: true) else { continue }
      var value = slate_gamepad_capabilities()
      if unsafe slate_gamepad_probe(candidate.rawValue, &value) == 0 {
        descriptor = candidate
        capabilities = value
        hasIdentity = unsafe slate_gamepad_get_identity(candidate.rawValue, &identity) == 0
        lastTouchDiscovery = nil
        return
      }
      try? candidate.close()
    }
  }
  private mutating func discoverTouchpad() {
    // A second bounded pass, matching the controller's nonempty unique ID and
    // hardware IDs. Never bind a different controller's touchpad by name alone.
    for index in 0..<64 {
      guard let candidate = openCandidate(index, reportErrors: false) else { continue }
      if unsafe slate_gamepad_probe_touchpad(candidate.rawValue, &identity) == 0 {
        touchpad = candidate
        return
      }
      try? candidate.close()
    }
  }
  private mutating func openCandidate(_ index: Int, reportErrors: Bool) -> FileDescriptor? {
    do {
      return try FileDescriptor.open(
        FilePath("/dev/input/event\(index)"), .readOnly, options: [.nonBlocking, .closeOnExec], retryOnInterrupt: false)
    } catch let error as Errno {
      if reportErrors {
        if error == .permissionDenied || error == .notPermitted {
          status = .permissionDenied
        } else if error != .noSuchFileOrDirectory && error != .operationNotSupportedByDevice && status == .disconnected
        {
          status = .unavailable(errno: error.rawValue)
        }
      }
      return nil
    } catch { preconditionFailure("FileDescriptor.open only throws Errno") }
  }
  deinit {
    if let touchpad { try? touchpad.close() }
    if let descriptor { try? descriptor.close() }
  }
}

func stateFromLinux(_ raw: slate_gamepad_state, capabilities: slate_gamepad_capabilities) -> GamepadState {
  let buttons = GamepadButtons(rawValue: raw.buttons)
  let hasLeft = capabilities.axes & UInt8(SLATE_GAMEPAD_LEFT_TRIGGER) != 0
  let hasRight = capabilities.axes & UInt8(SLATE_GAMEPAD_RIGHT_TRIGGER) != 0
  return .init(
    connected: true, buttons: buttons,
    leftX: normalizeLinuxAxis(raw.x, minimum: raw.x_minimum, maximum: raw.x_maximum),
    leftY: -normalizeLinuxAxis(raw.y, minimum: raw.y_minimum, maximum: raw.y_maximum),
    rightX: normalizeLinuxAxis(raw.right_x, minimum: raw.right_x_minimum, maximum: raw.right_x_maximum),
    rightY: -normalizeLinuxAxis(raw.right_y, minimum: raw.right_y_minimum, maximum: raw.right_y_maximum),
    leftTrigger: hasLeft
      ? normalizeLinuxTrigger(raw.left_trigger, minimum: raw.left_trigger_minimum, maximum: raw.left_trigger_maximum)
      : (buttons.contains(.l2) ? 1 : 0),
    rightTrigger: hasRight
      ? normalizeLinuxTrigger(raw.right_trigger, minimum: raw.right_trigger_minimum, maximum: raw.right_trigger_maximum)
      : (buttons.contains(.r2) ? 1 : 0),
    supportedButtons: .init(rawValue: capabilities.buttons),
    features: capabilities.axes & UInt8(SLATE_GAMEPAD_RIGHT_STICK) != 0 ? .rightStick : [])
}
func linuxTouch(_ raw: slate_gamepad_touch_state, secondary: Bool) -> GamepadTouch {
  let tracking = secondary ? raw.tracking.1 : raw.tracking.0
  guard tracking >= 0 else { return .init(isTouching: false) }
  return .init(
    x: normalizeLinuxAxis(secondary ? raw.x.1 : raw.x.0, minimum: raw.x_minimum, maximum: raw.x_maximum),
    y: -normalizeLinuxAxis(secondary ? raw.y.1 : raw.y.0, minimum: raw.y_minimum, maximum: raw.y_maximum),
    isTouching: true)
}
func normalizeLinuxAxis(_ value: Int32, minimum: Int32, maximum: Int32) -> Float {
  guard minimum < maximum else { return 0 }
  return normalizeLinuxTrigger(value, minimum: minimum, maximum: maximum) * 2 - 1
}
func normalizeLinuxTrigger(_ value: Int32, minimum: Int32, maximum: Int32) -> Float {
  guard minimum < maximum else { return 0 }
  let clamped = max(minimum, min(maximum, value))
  return Float(Int64(clamped) - Int64(minimum)) / Float(Int64(maximum) - Int64(minimum))
}
#endif
