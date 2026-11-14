import SlateGamepad
import Testing

@testable import SlateGamepad

@Test func gamepadTriggerThresholdsHysteresisInvalidValuesAndNeutralGate() {
  var latch = GamepadTriggerLatch()
  var state = GamepadState(connected: true, leftTrigger: 0.54, rightTrigger: 0.55)
  latch.apply(to: &state)
  #expect(state.buttons == .r2 && state.leftTrigger == 0.54)
  state.leftTrigger = 0.55
  state.rightTrigger = 0.45
  latch.apply(to: &state)
  #expect(state.buttons == [.l2, .r2])
  state.leftTrigger = 0.44
  state.rightTrigger = .nan
  latch.apply(to: &state)
  #expect(state.buttons.isEmpty && state.rightTrigger == 0)
  state.leftTrigger = 3
  state.rightTrigger = -1
  latch.apply(to: &state)
  #expect(state.leftTrigger == 1 && state.rightTrigger == 0 && state.buttons == .l2)
  #expect(!GamepadState(connected: true, leftTrigger: 0.2).isNeutral)
  #expect(!GamepadState(connected: true, primaryTouch: .init(isTouching: true)).isNeutral)
  #expect(GamepadState(connected: true, primaryTouch: .init(x: 1, y: 1)).isNeutral)
  #expect(!GamepadState(connected: true, rightX: .infinity).isNeutral)
  #expect(GamepadButtons.cross == .south && GamepadButtons.create == .secondaryMenu && GamepadButtons.options == .menu)
  var navigation = GamepadNavigation()
  #expect(navigation.update(.init(connected: true, leftTrigger: 0.2), at: .now).count == 0)
  #expect(navigation.update(.init(connected: true, buttons: .cross), at: .now).count == 0)
  _ = navigation.update(.init(connected: true), at: .now)
  #expect(navigation.update(.init(connected: true, buttons: .cross), at: .now)[0] == .activate)
}

#if os(macOS)
import GameController

@Test func gamepadMacMapsRemainingButtonsAndAnalogTriggers() throws {
  let controller = GCController.withExtendedGamepad()
  let pad = try #require(controller.extendedGamepad)
  pad.leftThumbstickButton?.setValue(1)
  pad.rightThumbstickButton?.setValue(1)
  pad.buttonMenu.setValue(1)
  pad.buttonOptions?.setValue(1)
  pad.buttonHome?.setValue(1)
  pad.leftTrigger.setValue(0.75)
  pad.rightTrigger.setValue(0.25)
  var state = PlatformGamepad.state(from: pad)
  var latch = GamepadTriggerLatch()
  latch.apply(to: &state)
  #expect(state.leftTrigger == 0.75 && state.rightTrigger == 0.25 && state.buttons.contains(.l2))
  #expect(!state.buttons.contains(.r2))
  #expect(state.buttons.contains(.options))
  for item in [GamepadButtons.l3, .r3, .create, .ps] where state.supportedButtons.contains(item) {
    #expect(state.buttons.contains(item))
  }
  #expect(!state.supportedButtons.contains(.microphoneMute))
  #expect(!state.features.contains(.touchContacts))
}

@Test func gamepadMacSystemGesturePreferencesRestore() throws {
  let controller = GCController.withExtendedGamepad()
  let pad = try #require(controller.extendedGamepad)
  let before = pad.buttonMenu.preferredSystemGestureState
  do {
    let lease = SystemGestureOverrides(pad)
    #expect(pad.buttonMenu.preferredSystemGestureState == .disabled)
    _ = consume lease
  }
  #expect(pad.buttonMenu.preferredSystemGestureState == before)
}
#elseif os(Linux)
import CLinuxGamepad
import CLinuxGamepadTestSupport
import SystemPackage

@Test func gamepadLinuxMapsAllKeysAxesAndDigitalTriggerFallback() {
  slate_gamepad_fixture_reset(0, 0)
  var capabilities = slate_gamepad_capabilities()
  #expect(slate_gamepad_probe_with_query(1, &capabilities, slate_gamepad_fixture_query) == 0)
  #expect(capabilities.axes == 31)
  #expect(GamepadButtons(rawValue: capabilities.buttons) == GamepadButtons.standard.union(.microphoneMute))
  #expect(slate_gamepad_fixture_query_count() == 2)
  var raw = slate_gamepad_state()
  slate_gamepad_fixture_reset(0, 0)
  #expect(slate_gamepad_read_state_with_query(1, capabilities.axes, &raw, slate_gamepad_fixture_query) == 0)
  #expect(slate_gamepad_fixture_query_count() == 9)
  var state = stateFromLinux(raw, capabilities: capabilities)
  var latch = GamepadTriggerLatch()
  latch.apply(to: &state)
  #expect(state.leftX == 1 && state.leftY == 1)
  #expect(state.leftTrigger == 1 && abs(state.rightTrigger - 0.502) < 0.001)
  #expect(state.buttons.contains(.l2) && !state.buttons.contains(.r2))
  #expect(
    state.buttons.contains(.l3) && state.buttons.contains(.r3) && state.buttons.contains(.create)
      && state.buttons.contains(.options) && state.buttons.contains(.ps))
  slate_gamepad_fixture_reset(4, 0)
  #expect(slate_gamepad_probe_with_query(1, &capabilities, slate_gamepad_fixture_query) == 0)
  #expect(capabilities.axes == 7)
  #expect(slate_gamepad_read_state_with_query(1, capabilities.axes, &raw, slate_gamepad_fixture_query) == 0)
  state = stateFromLinux(raw, capabilities: capabilities)
  #expect(state.leftTrigger == 1 && state.rightTrigger == 1)
  #expect(normalizeLinuxTrigger(.min, minimum: .min, maximum: .max) == 0)
  #expect(normalizeLinuxTrigger(.max, minimum: .min, maximum: .max) == 1)
}

@Test func gamepadLinuxTouchpadMatchesIdentityAndReportsTwoContactsWithoutCenterHeuristics() {
  slate_gamepad_fixture_reset(0, 0)
  var identity = slate_gamepad_identity()
  #expect(slate_gamepad_get_identity_with_query(1, &identity, slate_gamepad_fixture_query) == 0)
  #expect(slate_gamepad_probe_touchpad_with_query(2, &identity, slate_gamepad_fixture_query) == 0)
  #expect(
    slate_gamepad_probe_touchpad_with_query(3, &identity, slate_gamepad_fixture_query) == -Errno.notSupported.rawValue)
  slate_gamepad_fixture_reset(2, 0)
  #expect(
    slate_gamepad_probe_touchpad_with_query(2, &identity, slate_gamepad_fixture_query) == -Errno.overflow.rawValue)
  slate_gamepad_fixture_reset(1, 0)
  #expect(
    slate_gamepad_get_identity_with_query(1, &identity, slate_gamepad_fixture_query) == -Errno.notSupported.rawValue)
  slate_gamepad_fixture_reset(5, 0)
  #expect(
    slate_gamepad_probe_touchpad_with_query(2, &identity, slate_gamepad_fixture_query) == -Errno.notSupported.rawValue)
  slate_gamepad_fixture_reset(0, 0)
  var raw = slate_gamepad_touch_state()
  #expect(slate_gamepad_read_touchpad_with_query(2, &raw, slate_gamepad_fixture_query) == 0)
  #expect(slate_gamepad_fixture_query_count() == 6 && raw.pressed == 1)
  let first = linuxTouch(raw, secondary: false)
  let second = linuxTouch(raw, secondary: true)
  #expect(first.isTouching == true && abs(first.x) < 0.002 && abs(first.y) < 0.002)
  #expect(second.isTouching == false && second.x == 0 && second.y == 0)
}

@Test func gamepadLinuxQueryFailuresAreBoundedAndAtomicAtEveryStep() {
  for failure in 1...9 {
    slate_gamepad_fixture_reset(0, Int32(failure))
    var raw = slate_gamepad_state()
    raw.buttons = 123
    #expect(slate_gamepad_read_state_with_query(1, 31, &raw, slate_gamepad_fixture_query) == -Errno.ioError.rawValue)
    #expect(raw.buttons == 123 && slate_gamepad_fixture_query_count() == failure)
  }
  for failure in 1...6 {
    slate_gamepad_fixture_reset(0, Int32(failure))
    var raw = slate_gamepad_touch_state()
    raw.pressed = 123
    #expect(slate_gamepad_read_touchpad_with_query(2, &raw, slate_gamepad_fixture_query) == -Errno.ioError.rawValue)
    #expect(raw.pressed == 123 && slate_gamepad_fixture_query_count() == failure)
  }
  slate_gamepad_fixture_reset(3, 0)
  var cap = slate_gamepad_capabilities()
  cap.axes = 99
  #expect(
    slate_gamepad_probe_with_query(1, &cap, slate_gamepad_fixture_query) == -Errno.notSupported.rawValue
      && cap.axes == 99)
  slate_gamepad_fixture_reset(6, 0)
  var raw = slate_gamepad_state()
  raw.buttons = 123
  #expect(
    slate_gamepad_read_state_with_query(1, 31, &raw, slate_gamepad_fixture_query) == -Errno.invalidArgument.rawValue
      && raw.buttons == 123)
}
#endif
