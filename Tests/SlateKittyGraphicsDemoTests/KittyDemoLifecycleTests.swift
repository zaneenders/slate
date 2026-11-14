import Foundation
import SlateTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test(arguments: ["\r", "\u{3}", "\u{1b}", "q", "\u{1b}[99;5u"])
func kittyDemoDeletesItsImageAndRestoresTerminalAfterExitKeys(_ key: String) throws {
  let child = try TerminalChild(executable: "kitty-graphics")
  try child.awaitOutput(",C=1,q=2\u{1b}\\\u{1b}8")
  #expect(try attributes(of: child.pty.slave).c_lflag & tcflag_t(ICANON | ISIG) == 0)
  try child.send(key)
  try child.expectExit(status: 0)
  try expectRestored(child)
}

@Test(arguments: terminalTerminationSignals)
func kittyDemoDeletesItsImageBeforeRestoringTerminalAfterSignals(_ number: Int32) throws {
  let child = try TerminalChild(executable: "kitty-graphics")
  try child.awaitOutput(",C=1,q=2\u{1b}\\\u{1b}8")
  try #require(kill(child.pid, number) == 0)
  try child.expectExit(status: 128 + number)
  try expectRestored(child)
}

@Test func kittyDemoRepositionsOnResizeWithoutUploadingAgain() throws {
  let child = try TerminalChild(executable: "kitty-graphics")
  try child.awaitOutput(",c=78,r=21,z=0,C=1,q=2\u{1b}\\\u{1b}8")
  var size = winsize(ws_row: 16, ws_col: 60, ws_xpixel: 0, ws_ypixel: 0)
  try #require(unsafe ioctl(child.pty.slave, UInt(TIOCSWINSZ), &size) == 0)
  try child.awaitOutput(",c=58,r=13,z=0,C=1,q=2\u{1b}\\\u{1b}8")
  try child.send("\r")
  try child.expectExit(status: 0)
  #expect(child.output.components(separatedBy: "\u{1b}_Ga=t,").count - 1 == 1)
  try expectRestored(child)
}

private func expectRestored(_ child: TerminalChild) throws {
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  let deletion = try #require(child.output.range(of: "\u{1b}_Ga=d,d=I,i=1,q=2\u{1b}\\"))
  let restored = try #require(child.output.range(of: "\u{1b}[?25h\u{1b}[?1049l"))
  #expect(deletion.upperBound <= restored.lowerBound)
}
