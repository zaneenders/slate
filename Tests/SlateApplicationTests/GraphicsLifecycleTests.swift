import Foundation
import SlateApplication
import SlateTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test(arguments: [false, true])
func graphicsHooksPresentAfterCellsAndClearBeforeRestorationOnQuitOrFailure(_ failPresentation: Bool) throws {
  let pty = try graphicsLifecycleTerminal()
  let saved = try attributes(of: pty.slave)
  let keyboard = try Output(fileDescriptor: pty.master)
  try keyboard.writeAll("q".utf8Span.span)
  var application = GraphicsLifecycleApplication()
  application.probe.failPresentation = failPresentation
  do {
    try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
    #expect(!failPresentation)
  } catch { #expect(failPresentation && error == .graphics(.emptyRegion)) }
  #expect(application.probe.calls == ["cells", "graphics", "cleanup"])
  expectEqual(try attributes(of: pty.slave), saved)
  try expectGraphicsCleanupBeforeScreenRestore(on: pty.master)
}

@Test func graphicsCleanupFailureRetriesBeforeScreenRestorationAndReportsTheFirstError() throws {
  let pty = try graphicsLifecycleTerminal()
  let saved = try attributes(of: pty.slave)
  let keyboard = try Output(fileDescriptor: pty.master)
  try keyboard.writeAll("q".utf8Span.span)
  var application = GraphicsLifecycleApplication()
  application.probe.failFirstCleanup = true
  #expect(throws: ScreenApplicationError.graphics(.invalidImageID)) {
    try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
  }
  #expect(application.probe.calls == ["cells", "graphics", "cleanup", "cleanup"])
  expectEqual(try attributes(of: pty.slave), saved)
  try expectGraphicsCleanupBeforeScreenRestore(on: pty.master)
}

private func graphicsLifecycleTerminal() throws -> PseudoTerminal {
  let pty = try PseudoTerminal()
  var size = winsize(ws_row: 2, ws_col: 8, ws_xpixel: 0, ws_ypixel: 0)
  try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
  return pty
}

private func expectGraphicsCleanupBeforeScreenRestore(on descriptor: Int32) throws {
  let input = try Input(fileDescriptor: descriptor)
  var bytes = InlineArray<4_096, UInt8>(repeating: 0)
  let count = try input.read(into: bytes.mutableSpan)
  let text = bytes.span.extracting(first: count).withUnsafeBufferPointer { unsafe String(decoding: $0, as: UTF8.self) }
  // The cleanup command must precede the final cursor and main-screen restore.
  let deletion = try #require(text.range(of: "\u{1b}_Ga=d,d=I,i=123,q=2\u{1b}\\"))
  let restored = try #require(text.range(of: "\u{1b}[?25h\u{1b}[?1049l"))
  #expect(deletion.upperBound <= restored.lowerBound)
}

private final class GraphicsLifecycleProbe {
  var calls: [String] = []
  var failPresentation = false
  var failFirstCleanup = false
}

private struct GraphicsLifecycleApplication: ScreenApplication {
  let probe = GraphicsLifecycleProbe()

  func render(in size: TerminalSize) -> some Block {
    probe.calls.append("cells")
    return Text("cells")
  }

  mutating func presentGraphics(in size: TerminalSize, to output: borrowing Output) throws(KittyGraphicsError) {
    probe.calls.append("graphics")
    if probe.failPresentation { throw .emptyRegion }
  }

  mutating func clearGraphics(to output: borrowing Output) throws(KittyGraphicsError) {
    probe.calls.append("cleanup")
    if probe.failFirstCleanup {
      probe.failFirstCleanup = false
      throw .invalidImageID
    }
    try output.deleteKittyImage(id: 123)
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(.character("q"), _): return .quit
    default: return .none
    }
  }
}
