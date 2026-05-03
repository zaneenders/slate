import Testing

@testable import SlateCore

@Suite struct TerminalKeyDecoderTests {

  private func collect(
    chunks: [[UInt8]],
    flush: Bool = false
  ) -> [TerminalKeyEvent] {
    var decoder = TerminalKeyDecoder()
    var events: [TerminalKeyEvent] = []
    for chunk in chunks {
      decoder.decode(ContiguousArray(chunk)) { events.append($0) }
    }
    if flush {
      decoder.flush { events.append($0) }
    }
    return events
  }

  @Test func decodes_printableAscii_andSpace() {
    let ev = collect(chunks: [[32, 65, 126]])  // space, A, ~
    #expect(ev == [.character(" "), .character("A"), .character("~")])
  }

  @Test func decodes_backspace_8_and_127() {
    #expect(collect(chunks: [[8]]) == [.backspace])
    #expect(collect(chunks: [[127]]) == [.backspace])
  }

  @Test func decodes_tab() {
    #expect(collect(chunks: [[9]]) == [.tab])
  }

  @Test func decodes_enter_lf_and_cr() {
    #expect(collect(chunks: [[10]]) == [.enter])
    #expect(collect(chunks: [[13]]) == [.enter])
  }

  @Test func decodes_ctrl_bytes() {
    #expect(collect(chunks: [[1]]) == [.ctrl(1)])
    #expect(collect(chunks: [[31]]) == [.ctrl(31)])
  }

  @Test func escape_byte_followed_by_nonBracket_emitsEscape_andContinues() {
    let ev = collect(chunks: [[0x1B, 65]])
    #expect(ev == [.escape, .character("A")])
  }

  @Test func lone_escape_at_chunk_end_buffers_thenFlush_emitsEscape() {
    var d = TerminalKeyDecoder()
    var ev: [TerminalKeyEvent] = []
    d.decode(ContiguousArray([0x1B])) { ev.append($0) }
    #expect(ev.isEmpty)
    d.flush { ev.append($0) }
    #expect(ev == [.escape])
  }

  @Test func csi_arrow_keys_empty_params() {
    #expect(collect(chunks: [[0x1B, 0x5B, 0x41]]) == [.arrowUp])
    #expect(collect(chunks: [[0x1B, 0x5B, 0x42]]) == [.arrowDown])
    #expect(collect(chunks: [[0x1B, 0x5B, 0x43]]) == [.arrowRight])
    #expect(collect(chunks: [[0x1B, 0x5B, 0x44]]) == [.arrowLeft])
    #expect(collect(chunks: [[0x1B, 0x5B, 0x48]]) == [.home])
    #expect(collect(chunks: [[0x1B, 0x5B, 0x46]]) == [.end])
  }

  @Test func csi_unknown_empty_params_nonArrowFinal() {
    let ev = collect(chunks: [[0x1B, 0x5B, 0x47]])
    #expect(ev == [.unknown([0x1B, 0x5B, 0x47])])
  }

  @Test func csi_pageUp_pageDown() {
    #expect(collect(chunks: [[0x1B, 0x5B, 0x35, 0x7E]]) == [.pageUp])
    #expect(collect(chunks: [[0x1B, 0x5B, 0x36, 0x7E]]) == [.pageDown])
  }

  @Test func csi_bracketed_paste_markers() {
    #expect(collect(chunks: [[0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]]) == [.bracketedPasteStart])
    #expect(collect(chunks: [[0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]]) == [.bracketedPasteEnd])
  }

  @Test func csi_shiftEnter_kitty_u() {
    #expect(collect(chunks: [[0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75]]) == [.shiftEnter])
  }

  @Test func csi_shiftEnter_xterm_tilde() {
    #expect(
      collect(chunks: [[0x1B, 0x5B, 0x32, 0x37, 0x3B, 0x32, 0x3B, 0x31, 0x33, 0x7E]])
        == [.shiftEnter])
    #expect(collect(chunks: [[0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x7E]]) == [.shiftEnter])
  }

  @Test func csi_u_unknown_emits_unknown() {
    let ev = collect(chunks: [[0x1B, 0x5B, 0x31, 0x75]])
    #expect(ev == [.unknown([0x1B, 0x5B, 0x31, 0x75])])
  }

  @Test func csi_tilde_unknown_param_emits_unknown() {
    let ev = collect(chunks: [[0x1B, 0x5B, 0x39, 0x7E]])
    #expect(ev == [.unknown([0x1B, 0x5B, 0x39, 0x7E])])
  }

  @Test func csi_splitAcrossChunks_buffersUntilFinal() {
    let ev = collect(chunks: [
      [0x1B, 0x5B],
      [0x31, 0x3B, 0x32, 0x48],
    ])
    #expect(ev == [.unknown([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x48])])
  }

  @Test func utf8_twoByte_char_single_chunk() {
    let ev = collect(chunks: [[0xC3, 0xA9]])
    #expect(ev == [.character("é")])
  }

  @Test func utf8_twoByte_char_splitAcrossChunks() {
    let ev = collect(chunks: [[0xC3], [0xA9]])
    #expect(ev == [.character("é")])
  }

  @Test func utf8_incompleteAtEnd_flush_emitsReplacement() {
    var d = TerminalKeyDecoder()
    var ev: [TerminalKeyEvent] = []
    d.decode(ContiguousArray([0xC3])) { ev.append($0) }
    #expect(ev.isEmpty)
    d.flush { ev.append($0) }
    #expect(ev == [.character("\u{FFFD}")])
  }

  @Test func utf8_invalid_lead_replaced() {
    let ev = collect(chunks: [[0xFF]], flush: true)
    #expect(ev == [.character("\u{FFFD}")])
  }

  @Test func utf8_interruptedByEscape_emitsReplacement_then_csi() {
    let ev = collect(chunks: [[0xC3, 0x1B, 0x5B, 0x41]])
    #expect(ev == [.character("\u{FFFD}"), .arrowUp])
  }

  @Test func flush_nonEscape_overflow_emits_unknown() {
    var d = TerminalKeyDecoder()
    var ev: [TerminalKeyEvent] = []
    d.decode(ContiguousArray([0x1B, 0x5B, 0x31])) { ev.append($0) }
    d.flush { ev.append($0) }
    #expect(ev == [.unknown([0x1B, 0x5B, 0x31])])
  }

  @Test func decodes_utf8_beforeCSI_in_one_chunk() {
    let ev = collect(chunks: [[0xC3, 0xA9, 0x1B, 0x5B, 0x42]])
    #expect(ev == [.character("é"), .arrowDown])
  }
}
