#if canImport(Darwin) || canImport(Glibc)
import CIOTestSupport
import Foundation
import SlateGamepad
import Testing

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
#endif
