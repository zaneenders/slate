import SlateTestSupport
import Testing

@testable import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test func ticksDefaultTo50MillisecondsAndSkipMissedUpdates() throws {
  #expect(DefaultTickApplication().tickInterval == .milliseconds(50))
  var runner = try ScreenRunner(configuration: .init())
  var application = TickApplication()
  let start = ContinuousClock().now
  #expect(try runner.pollTimeout(at: start, application: application) == 50)
  #expect(try runner.tick(at: start.advanced(by: .milliseconds(49)), application: &application))
  #expect(application.probe.elapsed.isEmpty)
  #expect(try runner.pollTimeout(at: start.advanced(by: .milliseconds(49)), application: application) == 1)
  let due = start.advanced(by: .milliseconds(50))
  #expect(try runner.tick(at: due, application: &application))
  #expect(application.probe.elapsed == [.milliseconds(50)])
  #expect(try runner.tick(at: due, application: &application))
  let late = start.advanced(by: .seconds(3_600))
  #expect(try runner.tick(at: late, application: &application))
  #expect(application.probe.elapsed == [.milliseconds(50), .seconds(3_600) - .milliseconds(50)])
  #expect(try runner.tick(at: late, application: &application))
  #expect(try runner.pollTimeout(at: late, application: application) == 50)
  #expect(application.probe.elapsed.count == 2)
}

@Test func tickIntervalChangesPauseAndResumeRestartScheduling() throws {
  var runner = try ScreenRunner(configuration: .init())
  var application = TickApplication()
  application.tickInterval = .milliseconds(16)
  let start = ContinuousClock().now
  #expect(try runner.pollTimeout(at: start, application: application) == 16)
  #expect(try runner.pollTimeout(at: start.advanced(by: .milliseconds(5)), application: application) == 11)
  application.tickInterval = nil
  let paused = start.advanced(by: .seconds(1))
  #expect(try runner.pollTimeout(at: paused, application: application) == 50)
  #expect(try runner.tick(at: paused, application: &application))
  #expect(application.probe.elapsed.isEmpty)
  application.tickInterval = .milliseconds(16)
  #expect(try runner.pollTimeout(at: paused, application: application) == 16)
  #expect(try runner.tick(at: paused.advanced(by: .milliseconds(15)), application: &application))
  #expect(application.probe.elapsed.isEmpty)
  #expect(try runner.tick(at: paused.advanced(by: .milliseconds(16)), application: &application))
  #expect(application.probe.elapsed == [.milliseconds(16)])
  application.tickInterval = .milliseconds(32)
  #expect(try runner.pollTimeout(at: paused.advanced(by: .milliseconds(17)), application: application) == 32)
  #expect(try runner.tick(at: paused.advanced(by: .milliseconds(49)), application: &application))
  #expect(application.probe.elapsed == [.milliseconds(16), .milliseconds(32)])
  runner.resume()
  #expect(try runner.pollTimeout(at: paused.advanced(by: .seconds(2)), application: application) == 32)
  #expect(try runner.tick(at: paused.advanced(by: .seconds(2)), application: &application))
  #expect(application.probe.elapsed.count == 2)
}

@Test func tickPollingRoundsUpAndHandlesHugeOrInvalidIntervals() throws {
  let start = ContinuousClock().now
  var schedule = TickSchedule()
  try schedule.synchronize(interval: .nanoseconds(1), at: start)
  #expect(schedule.timeoutMilliseconds(at: start) == 1)
  #expect(schedule.next(at: start) == nil)
  #expect(schedule.next(at: start.advanced(by: .nanoseconds(1))) == .nanoseconds(1))
  try schedule.synchronize(interval: .microseconds(1_500), at: start)
  #expect(schedule.timeoutMilliseconds(at: start) == 2)
  #expect(schedule.timeoutMilliseconds(at: start.advanced(by: .milliseconds(1))) == 1)
  #expect(schedule.timeoutMilliseconds(at: start.advanced(by: .milliseconds(2))) == 0)
  try schedule.synchronize(interval: .seconds(Int64.max), at: start)
  #expect(schedule.timeoutMilliseconds(at: start) == 50)
  #expect(schedule.next(at: start.advanced(by: .seconds(1))) == nil)
  for interval in [Duration.zero, .nanoseconds(-1)] {
    #expect(throws: ScreenApplicationError.invalidTickInterval) {
      try schedule.synchronize(interval: interval, at: start)
    }
  }
  try schedule.synchronize(interval: nil, at: start)
  #expect(schedule.timeoutMilliseconds(at: start) == 50)
  #expect(schedule.next(at: start.advanced(by: .seconds(1))) == nil)
}

@Test func ticksCoalesceRedrawsAndHonorNoneQuitAndPendingWork() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 4, rows: 1)
  var runner = try ScreenRunner(configuration: .init())
  var application = TickApplication()
  let start = ContinuousClock().now
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.frames == 1)
  _ = try runner.pollTimeout(at: start, application: application)
  application.update = .none
  #expect(try runner.tick(at: start.advanced(by: .milliseconds(50)), application: &application))
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.frames == 1)
  application.update = .redraw
  for milliseconds in [100, 150] {
    #expect(try runner.tick(at: start.advanced(by: .milliseconds(milliseconds)), application: &application))
  }
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.frames == 2)
  application.hasPendingWork = true
  #expect(try runner.pollTimeout(at: start.advanced(by: .milliseconds(151)), application: application) == 0)
  application.update = .quit
  #expect(try !runner.tick(at: start.advanced(by: .milliseconds(200)), application: &application))
  #expect(application.probe.elapsed.count == 4)
}

@Test func applicationTicksWithoutInputAndQueuedQuitTakesPriority() throws {
  for queuedQuit in [false, true] {
    let pty = try PseudoTerminal()
    var size = winsize(ws_row: 1, ws_col: 4, ws_xpixel: 0, ws_ypixel: 0)
    try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
    if queuedQuit {
      let output = try Output(fileDescriptor: pty.master)
      try output.writeAll("q".utf8Span.span)
    }
    var application = TickApplication()
    application.tickInterval = .milliseconds(16)
    application.quitAfterTicks = 2
    try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
    #expect(application.probe.elapsed.count == (queuedQuit ? 0 : 2))
    #expect(application.probe.frames == (queuedQuit ? 1 : 2))
    #expect(application.probe.elapsed.allSatisfy { $0 >= .milliseconds(16) })
  }
}

@Test func invalidInitialTickIntervalsFailBeforeChangingTerminalModes() throws {
  let pty = try PseudoTerminal()
  let saved = try attributes(of: pty.slave)
  for interval in [Duration.zero, .milliseconds(-1)] {
    var application = TickApplication()
    application.tickInterval = interval
    #expect(throws: ScreenApplicationError.invalidTickInterval) {
      try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
    }
    expectEqual(try attributes(of: pty.slave), saved)
    #expect(application.probe.frames == 0 && application.probe.elapsed.isEmpty)
  }
}

private struct DefaultTickApplication: ScreenApplication {
  func render(in size: TerminalSize) -> some Block { Text("") }
}

private final class TickProbe {
  var elapsed: [Duration] = []
  var frames = 0
}

private struct TickApplication: ScreenApplication, ~Copyable {
  let probe = TickProbe()
  var tickInterval: Duration? = .milliseconds(50)
  var hasPendingWork = false
  var update = ScreenUpdate.redraw
  var quitAfterTicks = Int.max

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .tick(let elapsed):
      probe.elapsed.append(elapsed)
      return probe.elapsed.count >= quitAfterTicks ? .quit : update
    case .key(.character("q"), _): return .quit
    default: return .none
    }
  }

  func render(in size: TerminalSize) -> some Block {
    probe.frames += 1
    return Text("tick")
  }
}
