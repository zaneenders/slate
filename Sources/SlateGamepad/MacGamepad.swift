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
  private(set) var status = GamepadStatus.disconnected

  mutating func sample(at now: ContinuousClock.Instant) -> GamepadState {
    precondition(Thread.isMainThread, "Gamepad.poll must run on the main thread on macOS")
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
        controller = candidate
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
    return Self.state(from: pad)
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
    return .init(
      connected: true, buttons: buttons,
      leftX: pad.leftThumbstick.xAxis.value, leftY: pad.leftThumbstick.yAxis.value)
  }

  deinit {
    if let previousBackgroundMonitoring {
      GCController.shouldMonitorBackgroundEvents = previousBackgroundMonitoring
      Self.sessionClaimed.withLock { $0 = false }
    }
  }
}
#endif
