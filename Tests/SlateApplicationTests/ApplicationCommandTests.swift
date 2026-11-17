import SlateTestSupport
import Testing

@testable import SlateApplication

@Test @MainActor func genericCommandsPreserveOrderAndOwnedPayloadsAtEveryInputSplit() throws {
  let bytes = Array("a\u{1b}_Xmode=ready\u{1b}\\b\u{1b}_Gi=7;OK\u{1b}\\\u{1b}_Gi=0;OK\u{1b}\\qz".utf8)
  for split in 0...bytes.count {
    var runner = try ScreenRunner(configuration: .init())
    var application = CommandApplication()
    let now = ContinuousClock().now
    #expect(
      try runner.receive(bytes.span.extracting(0..<split), at: now, application: &application)
        == !application.received.contains("q"))
    if !application.received.contains("q") {
      #expect(try !runner.receive(bytes.span.extracting(split...), at: now, application: &application))
    }
    #expect(application.received == ["a", "command", "b", "kitty", "command", "q"])
    #expect(
      application.commands == [
        ApplicationCommand("Xmode=ready".utf8Span.span), ApplicationCommand("Gi=0;OK".utf8Span.span)
      ])
  }
}

@Test @MainActor func genericCommandsKeepBoundedPrefixesAndConsumeTruncatedTails() throws {
  var runner = try ScreenRunner(configuration: .init())
  var application = CommandApplication()
  let body = String(repeating: "x", count: ApplicationCommand.maximumBytes + 20)
  let bytes = Array(("\u{1b}_" + body + "\u{1b}\\q").utf8)
  var offset = 0
  var running = true
  while offset < bytes.count && running {
    let end = min(offset + 64, bytes.count)
    running = try runner.receive(bytes.span.extracting(offset..<end), at: .now, application: &application)
    offset = end
  }
  #expect(!running && application.received == ["command", "q"])
  let command = try #require(application.commands.first)
  #expect(command.count == ApplicationCommand.maximumBytes && command.truncated)
  #expect(command == ApplicationCommand(body.utf8Span.span))
}

@Test @MainActor func genericCommandHandlersCanRequestRedrawOrQuitWithinABatch() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 1, rows: 1)
  var runner = try ScreenRunner(configuration: .init())
  var application = CommandApplication()
  #expect(try presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output))
  #expect(try !presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output))
  application.commandUpdate = .redraw
  #expect(try runner.receive("\u{1b}_Xready\u{1b}\\".utf8Span.span, at: .now, application: &application))
  #expect(try presentTestFrame(runner: &runner, application: &application, actualSize: size, to: output))
  application.commandUpdate = .quit
  #expect(try !runner.receive("\u{1b}_Xdone\u{1b}\\z".utf8Span.span, at: .now, application: &application))
  #expect(application.received == ["command", "command"])
}

private struct CommandApplication: ScreenApplication {
  var received: [String] = []
  var commands: [ApplicationCommand] = []
  var commandUpdate = ScreenUpdate.none

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .applicationCommand(let command):
      commands.append(command)
      received.append("command")
      return commandUpdate
    case .kittyGraphicsReply: received.append("kitty")
    case .key(.character(let scalar), _):
      received.append(String(scalar))
      if scalar == "q" { return .quit }
    default: Issue.record("Unexpected event")
    }
    return .none
  }

  func render(in size: TerminalSize) -> some Block { Text("x") }
}
