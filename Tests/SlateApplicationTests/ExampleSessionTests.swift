import SlateTestSupport
import Testing

@Test(arguments: [
  "starter", "async-updates", "navigation", "scoped-navigation", "keyboard", "graphics", "kitty-graphics"
])
func everyExampleRunsThroughTheAsyncSessionAndRestoresOnExit(_ executable: String) throws {
  let child = try TerminalChild(executable: executable)
  try child.awaitOutput("\u{1b}[?25l")
  try child.send(executable == "keyboard" ? "\u{11}" : "\u{3}")
  try child.expectExit(status: 0)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
}
