#if canImport(Darwin) || canImport(Glibc)
import CIOTestSupport
import Foundation
import SlateGamepad
import Testing
@testable import SlateGamepad
#if os(Linux)
import CLinuxGamepad
import CLinuxGamepadTestSupport
#endif

@Suite(.serialized)
struct GamepadAllocationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func gamepadAllocationAtMaximumActionsAndReconnects() throws {
    try #require(cli_test_prepare_allocation_counter() != 0, "Allocation interposer was not injected")
    var navigation = GamepadNavigation()
    let now = ContinuousClock.now
    _ = exercise(&navigation, at: now)
    cli_test_begin_allocation_count()
    var actionCount = 0
    for _ in 0..<1_000 { actionCount += exercise(&navigation, at: now) }
    let calls = cli_test_end_allocation_count()
    #expect(calls == 0)
    #expect(actionCount == 10_000)
    print("Gamepad translation: 1,000 maximum-action/repeat/reconnect cycles, \(calls) allocation calls")
    print(
      "Inline storage: navigation \(MemoryLayout<GamepadNavigation>.stride) bytes, actions \(MemoryLayout<GamepadActions>.stride) bytes"
    )
  }

  @inline(never)
  private func exercise(_ navigation: inout GamepadNavigation, at now: ContinuousClock.Instant) -> Int {
    var count = navigation.update(.init(), at: now).count
    count += navigation.update(.init(connected: true, buttons: .south), at: now).count
    count += navigation.update(.init(connected: true), at: now).count
    let maximum = GamepadState(connected: true, buttons: [.south, .west, .up])
    count += navigation.update(maximum, at: now).count
    count += navigation.update(maximum, at: now + .milliseconds(350)).count
    count += navigation.update(maximum, at: now + .seconds(30)).count
    count += navigation.update(.init(connected: true), at: now + .seconds(31)).count
    count +=
      navigation.update(.init(connected: true, buttons: [.east, .south, .west, .down]), at: now + .seconds(32)).count
    count += navigation.update(.init(connected: true, leftX: -1), at: now + .seconds(33)).count
    count += navigation.update(.init(connected: true, leftY: 1), at: now + .seconds(34)).count
    return count
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
  func gamepadAllocationWithAllControlsAndAuxiliaryTouchpad() throws {
    try #require(cli_test_prepare_allocation_counter() != 0)
    var latch = GamepadTriggerLatch()
    var state = GamepadState(connected: true, buttons: .standard, leftTrigger: 1, rightTrigger: 0.5)
    #if os(Linux)
    slate_gamepad_fixture_reset(0, 0)
    var capabilities = slate_gamepad_capabilities()
    try #require(slate_gamepad_probe_with_query(1, &capabilities, slate_gamepad_fixture_query) == 0)
    var raw = slate_gamepad_state()
    var touch = slate_gamepad_touch_state()
    _ = slate_gamepad_read_state_with_query(1, capabilities.axes, &raw, slate_gamepad_fixture_query)
    _ = slate_gamepad_read_touchpad_with_query(2, &touch, slate_gamepad_fixture_query)
    state = stateFromLinux(raw, capabilities: capabilities)
    state.primaryTouch = linuxTouch(touch, secondary: false)
    #endif
    for _ in 0..<4 {
      latch.apply(to: &state)
      _ = state.isNeutral
    }
    cli_test_begin_allocation_count()
    var checksum = 0
    for _ in 0..<1_000 {
      #if os(Linux)
      slate_gamepad_fixture_reset(0, 0)
      checksum += Int(slate_gamepad_read_state_with_query(1, capabilities.axes, &raw, slate_gamepad_fixture_query))
      checksum += Int(slate_gamepad_read_touchpad_with_query(2, &touch, slate_gamepad_fixture_query))
      state = stateFromLinux(raw, capabilities: capabilities)
      state.primaryTouch = linuxTouch(touch, secondary: false)
      state.secondaryTouch = linuxTouch(touch, secondary: true)
      #endif
      latch.apply(to: &state)
      checksum += state.isNeutral ? 1 : 0
    }
    let calls = cli_test_end_allocation_count()
    #expect(calls == 0 && checksum == 0)
    #expect(state.buttons.contains(.l2) && !state.buttons.contains(.r2))
    print(
      "Full gamepad: 1,000 snapshots and trigger/touch updates, \(calls) allocation calls, \(MemoryLayout<GamepadState>.stride) bytes/snapshot"
    )
  }
}
#endif
