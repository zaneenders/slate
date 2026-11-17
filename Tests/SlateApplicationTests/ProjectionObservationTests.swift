import Observation
import SlateTestSupport
import Testing

@testable import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Test @MainActor func projectionObservationReplacesDependenciesCoalescesRefreshesAndStopsBeforeCleanup() async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try PseudoTerminal()
  var size = winsize(ws_row: 2, ws_col: 20, ws_xpixel: 0, ws_ypixel: 0)
  try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
  let probe = ProjectionProbe()
  var app = ProjectionApplication(probe: probe)
  let session = ScreenSession(maximumOutputBytes: 65_536, taskCapacity: 2)
  try await session.run(
    application: &app, inputFileDescriptor: pty.slave,
    outputFileDescriptor: pty.slave, signalHandling: .unchanged)
  #expect(probe.completed)
  #expect(probe.retiredBeforeCleanup)
}

@MainActor @Observable private final class ProjectionProbe {
  var alternate = false
  var left = 1
  var right = 2
  @ObservationIgnored var projected = 0
  @ObservationIgnored var runs = 0
  @ObservationIgnored var completed = false
  @ObservationIgnored var retiredBeforeCleanup = false
}

private struct ProjectionApplication: ScreenApplication {
  let probe: ProjectionProbe
  init(probe: ProjectionProbe) { self.probe = probe }

  mutating func start(in session: ScreenSession) {
    let probe = probe
    guard
      let observation = session.observe(
        at: 0,
        apply: {
          probe.projected = probe.alternate ? probe.right : probe.left
          probe.runs += 1
        })
    else { preconditionFailure("The observation slot must be available") }
    let accepted = session.startTask(at: 1) {
      defer { session.quit() }
      do {
        try await waitForProjection { probe.projected == 1 }
        probe.left = 10
        try await waitForProjection { probe.projected == 10 }
        probe.alternate = true
        try await waitForProjection { probe.projected == 2 }
        let previous = probe.runs
        probe.left = 11
        try await Task.sleep(for: .milliseconds(5))
        #expect(probe.runs == previous)
        probe.right = 20
        try await waitForProjection { probe.projected == 20 }
        let beforeRefresh = probe.runs
        for _ in 0..<64 { observation.refresh() }
        try await waitForProjection { probe.runs > beforeRefresh }
        #expect(probe.runs == beforeRefresh + 1)
        probe.completed = true
      } catch { Issue.record(error) }
    }
    precondition(accepted)
  }

  mutating func stop() async {
    let runs = probe.runs
    probe.left = 99
    probe.right = 100
    await Task.yield()
    probe.retiredBeforeCleanup = probe.runs == runs
  }

  func render(in size: TerminalSize) -> some Block { Text("Projected: \(probe.projected)") }
}

@MainActor private func waitForProjection(_ predicate: @MainActor () -> Bool) async throws {
  for _ in 0..<200 {
    if predicate() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  throw ProjectionTimeout.expired
}

private enum ProjectionTimeout: Error { case expired }
