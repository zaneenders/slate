import SlateGamepad
import Testing

@Test func gamepadEdgesRepeatDeadlinesAndDisconnect() {
  var navigation = GamepadNavigation()
  let start = ContinuousClock.now
  #expect(navigation.update(.init(connected: true), at: start).count == 0)
  let held = GamepadState(connected: true, buttons: [.right, .south, .west])
  let initial = navigation.update(held, at: start)
  #expect(initial.count == 3)
  #expect(initial[0] == .activate && initial[1] == .pause && initial[2] == .move(.right))
  #expect(navigation.update(held, at: start + .milliseconds(349)).count == 0)
  #expect(navigation.update(held, at: start + .milliseconds(350))[0] == .move(.right))
  #expect(navigation.update(held, at: start + .milliseconds(449)).count == 0)
  #expect(navigation.update(held, at: start + .milliseconds(450)).count == 1)
  // A delayed frame produces only one repeat, never a backlog.
  #expect(navigation.update(held, at: start + .seconds(30)).count == 1)
  #expect(navigation.update(held, at: start + .seconds(30)).count == 0)
  #expect(navigation.update(.init(), at: start + .seconds(31)).count == 0)
  // Reconnection while held cannot activate a newly selected control.
  #expect(navigation.update(held, at: start + .seconds(32)).count == 0)
  #expect(navigation.update(.init(connected: true), at: start + .seconds(33)).count == 0)
  #expect(navigation.update(held, at: start + .seconds(34)).count == 3)
}

@Test func gamepadNeutralGateOppositesAndButtonPrecedence() {
  var navigation = GamepadNavigation()
  let now = ContinuousClock.now
  #expect(navigation.update(.init(connected: true, buttons: .south), at: now).count == 0)
  #expect(navigation.update(.init(connected: true), at: now).count == 0)
  let buttons = navigation.update(.init(connected: true, buttons: [.south, .east]), at: now)
  #expect(buttons.count == 1 && buttons[0] == .back)
  let opposing = navigation.update(.init(connected: true, buttons: [.up, .down, .left, .right]), at: now)
  #expect(opposing.count == 0)
  let diagonal = navigation.update(.init(connected: true, buttons: [.up, .left]), at: now)
  #expect(diagonal.count == 1 && diagonal[0] == .move(.up))
  let switched = navigation.update(.init(connected: true, buttons: .right), at: now)
  #expect(switched.count == 1 && switched[0] == .move(.right))
}

@Test func gamepadStickThresholdsInvalidValuesAndDpadPriority() {
  var navigation = GamepadNavigation()
  let now = ContinuousClock.now
  _ = navigation.update(.init(connected: true), at: now)
  #expect(navigation.update(.init(connected: true, leftX: 0.549), at: now).count == 0)
  #expect(navigation.update(.init(connected: true, leftX: 0.55), at: now)[0] == .move(.right))
  #expect(navigation.update(.init(connected: true, leftX: 0.35), at: now + .seconds(1))[0] == .move(.right))
  #expect(navigation.update(.init(connected: true, leftX: 0.349), at: now + .seconds(2)).count == 0)
  #expect(navigation.update(.init(connected: true, leftX: 0.5), at: now + .seconds(3)).count == 0)
  #expect(navigation.update(.init(connected: true, leftX: .nan), at: now).count == 0)
  #expect(navigation.update(.init(connected: true, leftY: .infinity), at: now).count == 0)
  #expect(navigation.update(.init(connected: true, leftX: -1, leftY: 1), at: now)[0] == .move(.up))
  #expect(navigation.update(.init(connected: true, buttons: .down, leftX: -1), at: now)[0] == .move(.down))
}

#if os(Linux)
@testable import SlateGamepad

@Test func gamepadLinuxAxisRangesAreClampedAndCannotOverflow() {
  #expect(normalizeLinuxAxis(0, minimum: 0, maximum: 255) == -1)
  #expect(normalizeLinuxAxis(255, minimum: 0, maximum: 255) == 1)
  #expect(abs(normalizeLinuxAxis(128, minimum: 0, maximum: 255)) < 0.01)
  #expect(normalizeLinuxAxis(.min, minimum: .min, maximum: .max) == -1)
  #expect(normalizeLinuxAxis(.max, minimum: .min, maximum: .max) == 1)
  #expect(normalizeLinuxAxis(-100, minimum: 0, maximum: 255) == -1)
  #expect(normalizeLinuxAxis(0, minimum: 1, maximum: 1) == 0)
}
#endif
