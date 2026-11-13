import Foundation
import SlateTestSupport
import Testing

@testable import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
import Musl
#endif

@Test func applicationRoutesMouseEventsWithoutTurningThemIntoKeys() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var runner = try ScreenRunner(configuration: MouseApplication.configuration)
  var application = MouseApplication()
  let size = TerminalSize(columns: 4, rows: 2)
  try runner.draw(application: &application, actualSize: size, to: output)
  _ = try capture.take()
  let reports = "\u{1b}[<0;2;2M\u{1b}[<32;4;2M\u{1b}[<0;4;2m".utf8Span.span
  let continues = runner.receive(reports, at: .now, application: &application)
  #expect(continues)
  #expect(
    application.probe.events == [
      .init(action: .press, button: .left, column: 1, row: 1),
      .init(action: .move, button: .left, column: 3, row: 1),
      .init(action: .release, button: .left, column: 3, row: 1)
    ])
  #expect(application.probe.keys.isEmpty)
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.frames == 2)
  application.quitOnRelease = true
  let quit = "\u{1b}[<0;4;2mq".utf8Span.span
  let afterQuit = runner.receive(quit, at: .now, application: &application)
  #expect(!afterQuit && application.probe.keys.isEmpty)
}

@Test func applicationMouseTrackingIsScopedOnQuitAndLayoutFailure() throws {
  for failLayout in [false, true] {
    let pty = try PseudoTerminal()
    var size = winsize(ws_row: 2, ws_col: 4, ws_xpixel: 0, ws_ypixel: 0)
    try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
    let output = try Output(fileDescriptor: pty.master)
    try output.writeAll("q".utf8Span.span)
    var application = MouseApplication()
    application.failLayout = failLayout
    do {
      try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
      #expect(!failLayout)
    } catch {
      #expect(failLayout && error == .screen(.layout(.textTooLong)))
    }
    let received = try mouseSessionOutput(pty.master)
    #expect(received.contains("\u{1b}[?1006h\u{1b}[?1003h"))
    #expect(received.contains("\u{1b}[?1003l\u{1b}[?1006l"))
    let disable = try #require(received.range(of: "\u{1b}[?1003l"))
    let restore = try #require(received.range(of: "\u{1b}[?1049l"))
    #expect(disable.lowerBound < restore.lowerBound)
  }
}

@Test func applicationMouseTrackingRemainsOptIn() throws {
  #expect(!ScreenApplicationConfiguration().mouseTracking)
  let pty = try PseudoTerminal()
  var size = winsize(ws_row: 2, ws_col: 4, ws_xpixel: 0, ws_ypixel: 0)
  try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
  let output = try Output(fileDescriptor: pty.master)
  try output.writeAll("q".utf8Span.span)
  var application = NoMouseApplication()
  try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
  let received = try mouseSessionOutput(pty.master)
  #expect(!received.contains("\u{1b}[?1003") && !received.contains("\u{1b}[?1006"))
}

private final class MouseProbe {
  var events: [MouseEvent] = []
  var keys: [InputKey] = []
  var frames = 0
}

private struct MouseApplication: ScreenApplication, ~Copyable {
  let probe = MouseProbe()
  var failLayout = false
  var quitOnRelease = false
  static var configuration: ScreenApplicationConfiguration { .init(mouseTracking: true) }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .mouse(let mouse):
      probe.events.append(mouse)
      return quitOnRelease && mouse.action == .release ? .quit : .redraw
    case .key(let key, _):
      probe.keys.append(key)
      return key == .character("q") ? .quit : .none
    case .paste, .pasteEmpty, .pasteRejected, .tick: return .none
    }
  }

  @BlockBuilder func render(in size: TerminalSize) -> some Block {
    if failLayout {
      Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
    } else {
      Text("mouse")
    }
  }

  func paint(in frame: inout Frame) { probe.frames += 1 }
}

private struct NoMouseApplication: ScreenApplication {
  func render(in size: TerminalSize) -> some Block { Text("keys") }
  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key: return .quit
    default: return .none
    }
  }
}

private func mouseSessionOutput(_ descriptor: Int32) throws -> String {
  var bytes = InlineArray<4_096, UInt8>(repeating: 0)
  let input = try Input(fileDescriptor: descriptor)
  var result = ""
  for _ in 0..<16 {
    var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    try #require(unsafe poll(&readiness, 1, 100) == 1)
    let count = try input.read(into: bytes.mutableSpan)
    try #require(count > 0)
    result += bytes.span.extracting(first: count).withUnsafeBufferPointer {
      unsafe String(decoding: $0, as: UTF8.self)
    }
    if result.contains("\u{1b}[?1049l") { return result }
  }
  Issue.record("Session output exceeded the read budget")
  return result
}
