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

  // MARK: - Basic decoding

  @Test func enter_emitsEnter() {
    #expect(actions(from: [[10]]) == [.enter])
    #expect(actions(from: [[13]]) == [.enter])
  }

  @Test func backspace_emitsBackspace() {
    #expect(actions(from: [[8]]) == [.backspace])
    #expect(actions(from: [[127]]) == [.backspace])
  }

  @Test func tab_emitsTab() {
    #expect(actions(from: [[9]]) == [.tab])
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
    let acts = actions(from: [[0x1B, 65]]) // ESC, A
    #expect(acts == [.escape, .character("A")])
  }

  @Test func arrowKeys_emitted() {
    #expect(actions(from: [[0x1B, 0x5B, 0x41]]) == [.arrowUp])
    #expect(actions(from: [[0x1B, 0x5B, 0x42]]) == [.arrowDown])
  }

  // MARK: - Bracketed paste boundaries pass through

  @Test func bracketedPaste_boundaries_emitted() {
    let acts = actions(from: [
      [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], // \e[200~
      [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // \e[201~
    ])
    #expect(acts == [.bracketedPasteStart, .bracketedPasteEnd])
  }

  // MARK: - Paste-mode: handler does NOT convert — host owns that

  @Test func enter_duringPaste_stillEmitsEnter() {
    // Handler emits raw .enter regardless of paste state.
    // It's the host's job to check inPaste and treat it as a literal newline.
    let acts = actions(from: [
      [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], // \e[200~
      [10],                                     // Enter
      [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // \e[201~
    ])
    #expect(acts == [.bracketedPasteStart, .enter, .bracketedPasteEnd])
  }

  @Test func backspace_duringPaste_stillEmitsBackspace() {
    let acts = actions(from: [
      [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], // \e[200~
      [8],                                      // backspace
      [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // \e[201~
    ])
    #expect(acts == [.bracketedPasteStart, .backspace, .bracketedPasteEnd])
  }

  @Test func shiftEnter_emitsShiftEnter() {
    // CSI u kitty: \e[13;2u
    let acts = actions(from: [[0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75]])
    #expect(acts == [.shiftEnter])
  }

  @Test func multiLine_paste_entersAreUntransformed() {
    // "hello\nworld\n" inside paste — handler emits raw .enter for each LF.
    let acts = actions(from: [
      [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], // \e[200~
      Array("hello\nworld\n".utf8),
      [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // \e[201~
    ])
    #expect(acts == [
      .bracketedPasteStart,
      .character("h"), .character("e"), .character("l"), .character("l"), .character("o"),
      .enter,
      .character("w"), .character("o"), .character("r"), .character("l"), .character("d"),
      .enter,
      .bracketedPasteEnd,
    ])
  }
}
