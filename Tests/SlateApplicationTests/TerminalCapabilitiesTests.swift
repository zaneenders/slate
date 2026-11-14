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

@Test func asciiApplicationSkipsGraphemeModeAndRestoresTerminalOnQuitOrLayoutFailure() throws {
  #expect(ScreenApplicationConfiguration().capabilities == TerminalCapabilities())
  for failLayout in [false, true] {
    let pty = try PseudoTerminal()
    var size = winsize(ws_row: 1, ws_col: 4, ws_xpixel: 0, ws_ypixel: 0)
    try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
    let saved = try attributes(of: pty.slave)
    let input = try Output(fileDescriptor: pty.master)
    try input.writeAll("q".utf8Span.span)
    var application = ASCIIApplication()
    application.failLayout = failLayout
    do {
      try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
      #expect(!failLayout)
    } catch {
      #expect(failLayout && error == .screen(.layout(.textTooLong)))
    }
    expectEqual(try attributes(of: pty.slave), saved)
    let bytes = try terminalOutput(from: pty.master)
    #expect(!bytes.contains("\u{1b}[?2027"))
    #expect(bytes.contains("\u{1b}[?2004l") && bytes.contains("\u{1b}[?1049l"))
    if !failLayout { #expect(bytes.contains("38;2;1;2;3m? ?")) }
  }
}

private struct ASCIIApplication: ScreenApplication {
  var failLayout = false
  static var configuration: ScreenApplicationConfiguration {
    .init(capabilities: .init(color: .trueColor, unicode: .ascii))
  }

  @BlockBuilder func render(in size: TerminalSize) -> some Block {
    if failLayout {
      Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
    } else {
      Text("漢é", style: Style(foreground: .rgb(1, 2, 3)))
    }
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate { .quit }
}
