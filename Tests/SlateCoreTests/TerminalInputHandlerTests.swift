import Testing

@testable import SlateCore

@Suite struct TerminalInputHandlerTests {

  private func actions(from bytes: [[UInt8]]) -> [TerminalInputAction] {
    var handler = TerminalInputHandler()
    var result: [TerminalInputAction] = []
    for chunk in bytes {
      result.append(contentsOf: handler.handle(ContiguousArray(chunk)))
    }
    return result
  }

  // MARK: - Normal mode (outside paste)

  @Test func enter_outsidePaste_emitsEnter() {
    let acts = actions(from: [[10]]) // LF
    #expect(acts == [.enter])
  }

  @Test func backspace_outsidePaste_emitsBackspace() {
    let acts = actions(from: [[8]])
    #expect(acts == [.backspace])
  }

  @Test func tab_outsidePaste_emitsTab() {
    let acts = actions(from: [[9]])
    #expect(acts == [.tab])
  }

  @Test func characters_passThrough() {
    let acts = actions(from: [[65, 66, 67]]) // A B C
    #expect(acts == [.character("A"), .character("B"), .character("C")])
  }

  @Test func ctrlC_ctrlD_emitted() {
    #expect(actions(from: [[3]]) == [.ctrlC])
    #expect(actions(from: [[4]]) == [.ctrlD])
  }

  @Test func escape_emitted() {
    // ESC followed by non-bracket byte
    let acts = actions(from: [[0x1B, 65]])
    #expect(acts == [.escape, .character("A")])
  }

  @Test func arrowKeys_emitted() {
    #expect(actions(from: [[0x1B, 0x5B, 0x41]]) == [.arrowUp])
    #expect(actions(from: [[0x1B, 0x5B, 0x42]]) == [.arrowDown])
  }

  // MARK: - Paste mode conversions

  @Test func enter_duringPaste_emitsNewline() {
    // Bracketed paste: start, then Enter (LF), then end
    let acts = actions(from: [
      [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], // \e[200~
      [10],                                     // LF (would be .enter outside paste)
      [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // \e[201~
    ])
    #expect(acts == [
      .bracketedPasteStart,
      .newline,
      .bracketedPasteEnd,
    ])
  }

  @Test func backspace_duringPaste_isSuppressed() {
    let acts = actions(from: [
      [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], // \e[200~
      [8],                                      // backspace
      [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // \e[201~
    ])
    #expect(acts == [
      .bracketedPasteStart,
      // backspace suppressed
      .bracketedPasteEnd,
    ])
  }

  @Test func multiLine_paste_block_convertsEntersToNewlines() {
    // Simulate pasting "hello\nworld\n" — the terminal sends literal bytes
    // inside bracketed paste markers.
    let acts = actions(from: [
      [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], // \e[200~
      Array("hello\nworld\n".utf8),             // characters + LF bytes
      [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // \e[201~
    ])
    #expect(acts == [
      .bracketedPasteStart,
      .character("h"), .character("e"), .character("l"), .character("l"), .character("o"),
      .newline,
      .character("w"), .character("o"), .character("r"), .character("l"), .character("d"),
      .newline,
      .bracketedPasteEnd,
    ])
  }

  @Test func tab_duringPaste_emitted() {
    let acts = actions(from: [
      [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], // \e[200~
      [9],                                      // tab
      [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // \e[201~
    ])
    #expect(acts == [
      .bracketedPasteStart,
      .tab,
      .bracketedPasteEnd,
    ])
  }

  @Test func enter_afterPaste_resumesEmittingEnter() {
    // Paste ends, then a normal Enter should still emit .enter
    var handler = TerminalInputHandler()
    var acts: [TerminalInputAction] = []

    // Start paste, insert newline, end paste
    acts += handler.handle(ContiguousArray([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]))
    acts += handler.handle(ContiguousArray([10]))
    acts += handler.handle(ContiguousArray([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))

    #expect(acts == [.bracketedPasteStart, .newline, .bracketedPasteEnd])

    // Now a normal Enter outside paste
    acts = handler.handle(ContiguousArray([10]))
    #expect(acts == [.enter])
  }
}
