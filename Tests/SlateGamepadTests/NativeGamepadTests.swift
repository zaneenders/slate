import SlateGamepad
import Testing

@testable import SlateGamepad

#if os(macOS)
import GameController

@Test func gamepadMacProfileMapsPlayStationPositionsAndPositiveY() throws {
  let controller = GCController.withExtendedGamepad()
  let pad = try #require(controller.extendedGamepad)
  pad.buttonA.setValue(1)
  pad.buttonB.setValue(1)
  pad.buttonX.setValue(1)
  pad.dpad.setValueForXAxis(-1, yAxis: 1)
  pad.leftThumbstick.setValueForXAxis(0.75, yAxis: -0.8)
  let state = PlatformGamepad.state(from: pad)
  #expect(state.connected && state.buttons == [.up, .left, .south, .east, .west])
  #expect(state.leftX == 0.75 && state.leftY == -0.8)
  pad.buttonA.setValue(0)
  pad.buttonB.setValue(0)
  pad.buttonX.setValue(0)
  pad.dpad.setValueForXAxis(0, yAxis: 0)
  #expect(PlatformGamepad.state(from: pad).buttons.isEmpty)
}
#elseif os(Linux)
import CLinuxGamepad
import SystemPackage

@Test func gamepadLinuxQueryFailuresLeaveCallerStorageUnchanged() {
  var axes: UInt8 = 99
  #expect(slate_gamepad_probe(-1, &axes) == -Errno.badFileDescriptor.rawValue)
  #expect(axes == 99)
  var state = slate_gamepad_state()
  state.buttons = 99
  #expect(slate_gamepad_read_state(-1, 3, &state) == -Errno.badFileDescriptor.rawValue)
  #expect(state.buttons == 99)
}
#endif
