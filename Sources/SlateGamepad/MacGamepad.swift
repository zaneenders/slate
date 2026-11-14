#if os(macOS)
import CoreFoundation
import Foundation
import GameController
import Synchronization

struct PlatformGamepad: ~Copyable {
  private static let sessionClaimed = Mutex(false)
  private var controller: GCController?
  private var lastDiscovery: ContinuousClock.Instant?
  private var previousBackgroundMonitoring: Bool?
  private var triggers = GamepadTriggerLatch()
  private let captureSystemButtons: Bool
  private var systemGestures: SystemGestureOverrides?
  private(set) var status = GamepadStatus.disconnected

  init(captureSystemButtons: Bool = false) { self.captureSystemButtons = captureSystemButtons }

  mutating func sample(at now: ContinuousClock.Instant) -> GamepadState {
    precondition(Thread.isMainThread, "Gamepad input must run on the main thread on macOS")
    if previousBackgroundMonitoring == nil {
      Self.sessionClaimed.withLock { claimed in
        precondition(!claimed, "Only one active Gamepad reader is supported per process on macOS")
        claimed = true
      }
      previousBackgroundMonitoring = GCController.shouldMonitorBackgroundEvents
      // A terminal process isn't the frontmost GUI application.
      GCController.shouldMonitorBackgroundEvents = true
    }
    // One ready run-loop source, no waiting. The framework owns its internal work.
    _ = CFRunLoopRunInMode(.defaultMode, 0, true)
    if lastDiscovery == nil || lastDiscovery!.duration(to: now) >= .milliseconds(250) {
      lastDiscovery = now
      // Bridging the system list may allocate. Discovery is outside the warmed
      // translation guarantee, and we inspect at most sixteen devices per scan.
      let controllers = GCController.controllers()
      var retained = false
      var candidate: GCController?
      for index in 0..<min(16, controllers.count) {
        let item = controllers[index]
        if item === controller { retained = true }
        if candidate == nil && item.extendedGamepad != nil { candidate = item }
      }
      if !retained {
        systemGestures = nil
        controller = candidate
        if captureSystemButtons, let pad = candidate?.extendedGamepad {
          systemGestures = SystemGestureOverrides(pad)
        }
        triggers = .init()
        // Always deliver a disconnected sample between physical devices.
        status = .disconnected
        return .init()
      }
    }
    guard let pad = controller?.extendedGamepad else {
      status = .disconnected
      return .init()
    }
    status = .connected
    var state = Self.state(from: pad)
    triggers.apply(to: &state)
    return state
  }

  static func state(from pad: GCExtendedGamepad) -> GamepadState {
    var buttons: GamepadButtons = []
    if pad.dpad.up.isPressed { buttons.insert(.up) }
    if pad.dpad.down.isPressed { buttons.insert(.down) }
    if pad.dpad.left.isPressed { buttons.insert(.left) }
    if pad.dpad.right.isPressed { buttons.insert(.right) }
    if pad.buttonA.isPressed { buttons.insert(.south) }
    if pad.buttonB.isPressed { buttons.insert(.east) }
    if pad.buttonX.isPressed { buttons.insert(.west) }
    if pad.buttonY.isPressed { buttons.insert(.north) }
    if pad.leftShoulder.isPressed { buttons.insert(.leftShoulder) }
    if pad.rightShoulder.isPressed { buttons.insert(.rightShoulder) }
    if pad.leftThumbstickButton?.isPressed == true { buttons.insert(.leftStick) }
    if pad.rightThumbstickButton?.isPressed == true { buttons.insert(.rightStick) }
    if pad.buttonMenu.isPressed { buttons.insert(.menu) }
    if pad.buttonOptions?.isPressed == true { buttons.insert(.secondaryMenu) }
    if pad.buttonHome?.isPressed == true { buttons.insert(.home) }
    var supported = GamepadButtons.standard
    if pad.leftThumbstickButton == nil { supported.remove(.leftStick) }
    if pad.rightThumbstickButton == nil { supported.remove(.rightStick) }
    if pad.buttonOptions == nil { supported.remove(.secondaryMenu) }
    if pad.buttonHome == nil { supported.remove(.home) }
    var state = GamepadState(
      connected: true, buttons: buttons,
      leftX: pad.leftThumbstick.xAxis.value, leftY: pad.leftThumbstick.yAxis.value,
      rightX: pad.rightThumbstick.xAxis.value, rightY: pad.rightThumbstick.yAxis.value,
      leftTrigger: pad.leftTrigger.value, rightTrigger: pad.rightTrigger.value, supportedButtons: supported)
    if let dualSense = pad as? GCDualSenseGamepad {
      state.supportedButtons.insert(.touchpad)
      if dualSense.touchpadButton.isPressed { state.buttons.insert(.touchpad) }
      state.features.insert(.touchPositions)
      // GameController supplies two direction pads, without contact flags. Do
      // not treat (0,0), or a retained coordinate, as a finger-up/down event.
      state.primaryTouch = .init(x: dualSense.touchpadPrimary.xAxis.value, y: dualSense.touchpadPrimary.yAxis.value)
      state.secondaryTouch = .init(
        x: dualSense.touchpadSecondary.xAxis.value, y: dualSense.touchpadSecondary.yAxis.value)
    }
    return state
  }

  deinit {
    if let previousBackgroundMonitoring {
      GCController.shouldMonitorBackgroundEvents = previousBackgroundMonitoring
      Self.sessionClaimed.withLock { $0 = false }
    }
  }
}

/// The preferences are per element. Keep the exact old elements alive until
/// restoration, even if the controller disconnects before this scope ends.
struct SystemGestureOverrides: ~Copyable {
  private let menu: GCControllerButtonInput
  private let secondary: GCControllerButtonInput?
  private let home: GCControllerButtonInput?
  private let previousMenu: GCControllerElement.SystemGestureState
  private let previousSecondary: GCControllerElement.SystemGestureState?
  private let previousHome: GCControllerElement.SystemGestureState?
  init(_ pad: GCExtendedGamepad) {
    menu = pad.buttonMenu
    secondary = pad.buttonOptions
    home = pad.buttonHome
    previousMenu = menu.preferredSystemGestureState
    previousSecondary = secondary?.preferredSystemGestureState
    previousHome = home?.preferredSystemGestureState
    menu.preferredSystemGestureState = .disabled
    secondary?.preferredSystemGestureState = .disabled
    home?.preferredSystemGestureState = .disabled
  }
  deinit {
    if menu.preferredSystemGestureState == .disabled { menu.preferredSystemGestureState = previousMenu }
    if let secondary, let previousSecondary, secondary.preferredSystemGestureState == .disabled {
      secondary.preferredSystemGestureState = previousSecondary
    }
    if let home, let previousHome, home.preferredSystemGestureState == .disabled {
      home.preferredSystemGestureState = previousHome
    }
  }
}
#endif
