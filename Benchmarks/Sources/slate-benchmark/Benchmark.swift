import AllocationProbe
import Glibc

@main
enum SlateBenchmark {
  static func main() throws {
    #if DEBUG
    fatalError("Run with -c release")
    #else
    cli_probe_begin()
    let calibrated = cli_probe_calibrate()
    let cAllocations = cli_probe_end()
    precondition(calibrated == 1 && cAllocations == 6, "C allocator hooks failed")
    precondition(calibrateSwift() > 0, "Swift allocator hooks failed")
    defer { _ = cli_probe_end() }
    let start = ContinuousClock.now
    try runRenderingAllocations()
    try runEditingAllocations()
    try runRegionAllocations()
    print("Slate cell rendering, editing and regions: \(start.duration(to: .now))")
    try runSurfaceAllocations()
    #endif
  }

  @inline(never)
  private static func calibrateSwift() -> UInt64 {
    cli_probe_begin()
    let bytes = [UInt8](repeating: 7, count: 4096)
    bytes.withUnsafeBufferPointer { unsafe cli_probe_consume($0.baseAddress, $0.count) }
    return cli_probe_end()
  }
}
