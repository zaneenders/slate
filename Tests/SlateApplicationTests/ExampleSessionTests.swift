import SlateTestSupport
import Testing

@Test(arguments: ["\u{1}\u{3}", "\u{1b}[97;5u\u{1b}[99;69u"])
func starterCopiesASelectionAndReportsRejectedEdits(_ selectAndCopy: String) throws {
  let child = try TerminalChild(executable: "starter")
  try child.awaitOutput("Hello, Slate!")
  try child.send("hello" + selectAndCopy)
  try child.awaitOutput("\u{1b}]52;c;aGVsbG8=\u{1b}\\")
  try child.send("\u{1b}[200~" + String(repeating: "x", count: 4097) + "\u{1b}[201~")
  try child.awaitOutput("Input is limited to 4096 bytes.")
  // A failed replacement preserves the selection for the next edit.
  try child.send("ok" + selectAndCopy)
  try child.awaitOutput("\u{1b}]52;c;b2s=\u{1b}\\")
  try child.send("\u{1b}")
  try child.expectExit(status: 0)
}

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
