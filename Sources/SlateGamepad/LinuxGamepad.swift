#if os(Linux)
import CLinuxGamepad
import SystemPackage

struct PlatformGamepad: ~Copyable {
  private var descriptor: FileDescriptor?
  private var hatAxes: UInt8 = 0
  private var lastDiscovery: ContinuousClock.Instant?
  private(set) var status = GamepadStatus.disconnected

  mutating func sample(at now: ContinuousClock.Instant) -> GamepadState {
    if descriptor == nil {
      guard lastDiscovery == nil || lastDiscovery!.duration(to: now) >= .seconds(1) else { return .init() }
      lastDiscovery = now
      discover()
    }
    guard let descriptor else { return .init() }
    var raw = slate_gamepad_state()
    let result = unsafe slate_gamepad_read_state(descriptor.rawValue, hatAxes, &raw)
    guard result == 0 else {
      try? descriptor.close()
      self.descriptor = nil
      status = result == -Errno.operationNotSupportedByDevice.rawValue ? .disconnected : .unavailable(errno: -result)
      return .init()
    }
    status = .connected
    return .init(
      connected: true, buttons: .init(rawValue: raw.buttons),
      leftX: normalizeLinuxAxis(raw.x, minimum: raw.x_minimum, maximum: raw.x_maximum),
      leftY: -normalizeLinuxAxis(raw.y, minimum: raw.y_minimum, maximum: raw.y_maximum))
  }

  private mutating func discover() {
    status = .disconnected
    // Bounded startup/hotplug allocation path: 64 path strings and at most one
    // open descriptor at a time. Unsupported or inaccessible nodes are skipped.
    for index in 0..<64 {
      let candidate: FileDescriptor
      do {
        candidate = try FileDescriptor.open(
          FilePath("/dev/input/event\(index)"), .readOnly, options: [.nonBlocking, .closeOnExec],
          retryOnInterrupt: false)
      } catch let error as Errno {
        if error == .permissionDenied || error == .notPermitted {
          status = .permissionDenied
        } else if error != .noSuchFileOrDirectory && error != .operationNotSupportedByDevice {
          if status == .disconnected { status = .unavailable(errno: error.rawValue) }
        }
        continue
      } catch {
        preconditionFailure("FileDescriptor.open only throws Errno")
      }
      var axes: UInt8 = 0
      if unsafe slate_gamepad_probe(candidate.rawValue, &axes) == 0 {
        descriptor = candidate
        hatAxes = axes
        return
      }
      try? candidate.close()
    }
  }

  deinit { if let descriptor { try? descriptor.close() } }
}

func normalizeLinuxAxis(_ value: Int32, minimum: Int32, maximum: Int32) -> Float {
  guard minimum < maximum else { return 0 }
  // Widen before subtracting: evdev ranges can span the entire Int32 domain.
  let clamped = max(minimum, min(maximum, value))
  return Float(Int64(clamped) - Int64(minimum)) / Float(Int64(maximum) - Int64(minimum)) * 2 - 1
}
#endif
