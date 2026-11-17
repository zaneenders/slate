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
@MainActor
func graphicsHooksPresentAfterCellsAndClearBeforeRestorationOnQuitOrFailure(_ failPresentation: Bool) async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try graphicsLifecycleTerminal()
  let saved = try attributes(of: pty.slave)
  let keyboard = try Output(fileDescriptor: pty.master)
  try keyboard.writeAll("q".utf8Span.span)
  var application = GraphicsLifecycleApplication()
  application.probe.failPresentation = failPresentation
  do {
    try await ScreenSession(maximumOutputBytes: 1_048_576, taskCapacity: 4).run(
      application: &application, inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave,
      signalHandling: .unchanged)
    #expect(!failPresentation)
  } catch { #expect(failPresentation && error == .graphics(.emptyRegion)) }
  #expect(application.probe.calls == ["cells", "observed", "graphics", "cleanup"])
  expectEqual(try attributes(of: pty.slave), saved)
  try expectGraphicsCleanupBeforeScreenRestore(on: pty.master)
}

@Test @MainActor func graphicsCleanupFailureRetriesBeforeScreenRestorationAndReportsTheFirstError() async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try graphicsLifecycleTerminal()
  let saved = try attributes(of: pty.slave)
  let keyboard = try Output(fileDescriptor: pty.master)
  try keyboard.writeAll("q".utf8Span.span)
  var application = GraphicsLifecycleApplication()
  application.probe.failFirstCleanup = true
  await #expect(throws: ScreenApplicationError.graphics(.invalidImageID)) {
    try await ScreenSession(maximumOutputBytes: 1_048_576, taskCapacity: 4).run(
      application: &application, inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave,
      signalHandling: .unchanged)
  }
  #expect(application.probe.calls == ["cells", "observed", "graphics", "cleanup", "cleanup"])
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
  let text = try terminalOutput(from: descriptor)
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

  mutating func didPresentFrame(_ statistics: FrameStatistics) { probe.calls.append("observed") }

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
