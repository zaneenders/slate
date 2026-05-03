/// Synchronous state machine that converts raw bytes from a TTY into ``KeyEvent`` values.
///
/// Handles:
/// - UTF-8 multi-byte sequences.
/// - ANSI escape sequences (arrows, function keys, etc.).
/// - ASCII control characters (`Ctrl+C` = byte `0x03`).
/// - Bracketed paste mode (`CSI 200 ~` … `CSI 201 ~`): all bytes inside the paste
///   are emitted as `.character` events, including CR / LF / ESC.
public struct EscapeParser: Sendable {
  private enum State: Sendable {
    case ground
    case escape
    case csi
    case csiParam
    case ss3
    case utf8Remaining(count: Int, codepoint: UInt32)
    case paste
    case pasteEscape
    case pasteUtf8Remaining(count: Int, codepoint: UInt32)
  }

  private var state: State
  private var paramBuffer: [UInt8]
  private var pasteEscapeBuffer: [UInt8]

  public init() {
    self.state = .ground
    self.paramBuffer = []
    self.pasteEscapeBuffer = []
  }

  /// Feed one byte. Returns zero or more ``KeyEvent`` values.
  public mutating func feed(_ byte: UInt8) -> [KeyEvent] {
    var result: [KeyEvent] = []
    switch state {
    case .ground:
      feedGround(byte, into: &result)
    case .escape:
      feedEscape(byte, into: &result)
    case .csi:
      feedCsi(byte, into: &result)
    case .csiParam:
      feedCsiParam(byte, into: &result)
    case .ss3:
      feedSs3(byte, into: &result)
    case .utf8Remaining(let count, let codepoint):
      feedUtf8(byte, remaining: count, codepoint: codepoint, into: &result)
    case .paste:
      feedPaste(byte, into: &result)
    case .pasteEscape:
      feedPasteEscape(byte, into: &result)
    case .pasteUtf8Remaining(let count, let codepoint):
      feedPasteUtf8(byte, remaining: count, codepoint: codepoint, into: &result)
    }
    return result
  }

  // MARK: - Ground state

  private mutating func feedGround(_ byte: UInt8, into result: inout [KeyEvent]) {
    if byte == 0x1B {
      state = .escape
      return
    }

    // DEL (0x7F) is treated as backspace
    if byte == 0x7F {
      result.append(KeyEvent(code: .backspace))
      return
    }

    // Control characters (0x00–0x1F, excluding ESC which is handled above)
    if byte < 0x20 {
      result.append(parseControl(byte))
      return
    }

    // ASCII printable
    if byte < 0x80 {
      let scalar = Unicode.Scalar(byte)
      result.append(KeyEvent(code: .character(Character(scalar))))
      return
    }

    // UTF-8 start byte
    if byte & 0xE0 == 0xC0 {
      state = .utf8Remaining(count: 1, codepoint: UInt32(byte & 0x1F))
    } else if byte & 0xF0 == 0xE0 {
      state = .utf8Remaining(count: 2, codepoint: UInt32(byte & 0x0F))
    } else if byte & 0xF8 == 0xF0 {
      state = .utf8Remaining(count: 3, codepoint: UInt32(byte & 0x07))
    } else {
      // Invalid start byte; discard.
    }
  }

  // MARK: - Escape sequences

  private mutating func feedEscape(_ byte: UInt8, into result: inout [KeyEvent]) {
    if byte == 0x5B {  // [
      state = .csi
      return
    }
    if byte == 0x4F {  // O
      state = .ss3
      return
    }
    // ESC + char → Alt+char
    state = .ground
    let scalar = Unicode.Scalar(byte)
    if scalar.isASCII {
      result.append(KeyEvent(code: .character(Character(scalar)), modifiers: .alt))
    }
  }

  private mutating func feedCsi(_ byte: UInt8, into result: inout [KeyEvent]) {
    paramBuffer.removeAll()
    if byte >= 0x30 && byte <= 0x3F {
      paramBuffer.append(byte)
      state = .csiParam
      return
    }
    // No parameters; final byte follows immediately.
    let params = parseCsiParams(paramBuffer)
    parseCsi(params: params, final: byte, into: &result)
    state = .ground
  }

  private mutating func feedCsiParam(_ byte: UInt8, into result: inout [KeyEvent]) {
    if byte >= 0x30 && byte <= 0x3F {
      paramBuffer.append(byte)
      return
    }
    if byte >= 0x20 && byte <= 0x2F {
      // Intermediate byte (ignored for initial implementation).
      paramBuffer.append(byte)
      return
    }
    // Final byte

    // SGR mouse: CSI < Pb ; Px ; Py M/m  (< = 0x3C is a valid param byte)
    if paramBuffer.first == 0x3C && (byte == 0x4D || byte == 0x6D) {
      if byte == 0x4D {  // press only; wheel has no meaningful release
        let mouseParams = parseCsiParams(Array(paramBuffer.dropFirst()))
        if mouseParams.count >= 1 {
          switch mouseParams[0] {
          case 64: result.append(KeyEvent(code: .scrollUp))
          case 65: result.append(KeyEvent(code: .scrollDown))
          default: break
          }
        }
      }
      state = .ground
      paramBuffer.removeAll()
      return
    }

    let params = parseCsiParams(paramBuffer)

    // Bracketed paste start: CSI 200 ~
    if byte == 0x7E, params.first == 200 {
      state = .paste
      paramBuffer.removeAll()
      return
    }

    parseCsi(params: params, final: byte, into: &result)
    state = .ground
    paramBuffer.removeAll()
  }

  private mutating func feedSs3(_ byte: UInt8, into result: inout [KeyEvent]) {
    state = .ground
    if let event = parseSs3(final: byte) {
      result.append(event)
    }
  }

  // MARK: - UTF-8

  private mutating func feedUtf8(_ byte: UInt8, remaining: Int, codepoint: UInt32, into result: inout [KeyEvent]) {
    let newCodepoint = (codepoint << 6) | UInt32(byte & 0x3F)
    if remaining == 1 {
      state = .ground
      if let scalar = Unicode.Scalar(newCodepoint) {
        result.append(KeyEvent(code: .character(Character(scalar))))
      }
      return
    }
    state = .utf8Remaining(count: remaining - 1, codepoint: newCodepoint)
  }

  // MARK: - Bracketed paste

  private mutating func feedPaste(_ byte: UInt8, into result: inout [KeyEvent]) {
    if byte == 0x1B {
      state = .pasteEscape
      pasteEscapeBuffer = [0x1B]
      return
    }

    if byte < 0x80 {
      let scalar = Unicode.Scalar(byte)
      result.append(KeyEvent(code: .character(Character(scalar))))
      return
    }

    if byte & 0xE0 == 0xC0 {
      state = .pasteUtf8Remaining(count: 1, codepoint: UInt32(byte & 0x1F))
    } else if byte & 0xF0 == 0xE0 {
      state = .pasteUtf8Remaining(count: 2, codepoint: UInt32(byte & 0x0F))
    } else if byte & 0xF8 == 0xF0 {
      state = .pasteUtf8Remaining(count: 3, codepoint: UInt32(byte & 0x07))
    }
    // Invalid start byte; discard.
  }

  private mutating func feedPasteEscape(_ byte: UInt8, into result: inout [KeyEvent]) {
    let closeSeq: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // \e[201~
    pasteEscapeBuffer.append(byte)

    if pasteEscapeBuffer.count <= closeSeq.count {
      let prefix = Array(closeSeq.prefix(pasteEscapeBuffer.count))
      if prefix == pasteEscapeBuffer {
        if pasteEscapeBuffer.count == closeSeq.count {
          // Full match — exit paste mode.
          state = .ground
          pasteEscapeBuffer.removeAll()
          return
        }
        // Partial match — stay in pasteEscape.
        return
      }
    }

    // Mismatch — emit all buffered bytes as literal characters, then
    // re-process the current byte in paste mode.
    let currentByte = pasteEscapeBuffer.removeLast()
    for b in pasteEscapeBuffer {
      let scalar = Unicode.Scalar(b)
      result.append(KeyEvent(code: .character(Character(scalar))))
    }
    pasteEscapeBuffer.removeAll()
    state = .paste
    feedPaste(currentByte, into: &result)
  }

  private mutating func feedPasteUtf8(_ byte: UInt8, remaining: Int, codepoint: UInt32, into result: inout [KeyEvent]) {
    let newCodepoint = (codepoint << 6) | UInt32(byte & 0x3F)
    if remaining == 1 {
      state = .paste
      if let scalar = Unicode.Scalar(newCodepoint) {
        result.append(KeyEvent(code: .character(Character(scalar))))
      }
      return
    }
    state = .pasteUtf8Remaining(count: remaining - 1, codepoint: newCodepoint)
  }

  // MARK: - Parsers

  private func parseControl(_ byte: UInt8) -> KeyEvent {
    switch byte {
    case 0x00: return KeyEvent(code: .character(" "), modifiers: .control)
    case 0x01: return KeyEvent(code: .character("a"), modifiers: .control)
    case 0x02: return KeyEvent(code: .character("b"), modifiers: .control)
    case 0x03: return KeyEvent(code: .character("c"), modifiers: .control)
    case 0x04: return KeyEvent(code: .character("d"), modifiers: .control)
    case 0x05: return KeyEvent(code: .character("e"), modifiers: .control)
    case 0x06: return KeyEvent(code: .character("f"), modifiers: .control)
    case 0x07: return KeyEvent(code: .character("g"), modifiers: .control)
    case 0x08: return KeyEvent(code: .backspace)
    case 0x09: return KeyEvent(code: .tab)
    case 0x0A: return KeyEvent(code: .character("\n"))
    case 0x0B: return KeyEvent(code: .character("k"), modifiers: .control)
    case 0x0C: return KeyEvent(code: .character("l"), modifiers: .control)
    case 0x0D: return KeyEvent(code: .enter)
    case 0x0E: return KeyEvent(code: .character("n"), modifiers: .control)
    case 0x0F: return KeyEvent(code: .character("o"), modifiers: .control)
    case 0x10: return KeyEvent(code: .character("p"), modifiers: .control)
    case 0x11: return KeyEvent(code: .character("q"), modifiers: .control)
    case 0x12: return KeyEvent(code: .character("r"), modifiers: .control)
    case 0x13: return KeyEvent(code: .character("s"), modifiers: .control)
    case 0x14: return KeyEvent(code: .character("t"), modifiers: .control)
    case 0x15: return KeyEvent(code: .character("u"), modifiers: .control)
    case 0x16: return KeyEvent(code: .character("v"), modifiers: .control)
    case 0x17: return KeyEvent(code: .character("w"), modifiers: .control)
    case 0x18: return KeyEvent(code: .character("x"), modifiers: .control)
    case 0x19: return KeyEvent(code: .character("y"), modifiers: .control)
    case 0x1A: return KeyEvent(code: .character("z"), modifiers: .control)
    case 0x1C: return KeyEvent(code: .character("\\"), modifiers: .control)
    case 0x1D: return KeyEvent(code: .character("]"), modifiers: .control)
    case 0x1E: return KeyEvent(code: .character("^"), modifiers: .control)
    case 0x1F: return KeyEvent(code: .character("_"), modifiers: .control)
    default: return KeyEvent(code: .character("?"))
    }
  }

  private func parseCsiParams(_ bytes: [UInt8]) -> [Int] {
    var params: [Int] = []
    var current: Int = 0
    var hasCurrent = false
    for b in bytes {
      if b == 0x3B {  // ;
        params.append(hasCurrent ? current : 0)
        current = 0
        hasCurrent = false
      } else if b >= 0x30 && b <= 0x39 {
        current = current &* 10 &+ Int(b &- 0x30)
        hasCurrent = true
      }
    }
    params.append(hasCurrent ? current : 0)
    return params
  }

  private mutating func parseCsi(params: [Int], final: UInt8, into result: inout [KeyEvent]) {
    let mod: Modifiers = params.count >= 2 ? modifiersFromParam(params[1]) : []

    switch final {
    case 0x41: result.append(KeyEvent(code: .up, modifiers: mod)); return
    case 0x42: result.append(KeyEvent(code: .down, modifiers: mod)); return
    case 0x43: result.append(KeyEvent(code: .right, modifiers: mod)); return
    case 0x44: result.append(KeyEvent(code: .left, modifiers: mod)); return
    case 0x48: result.append(KeyEvent(code: .home, modifiers: mod)); return
    case 0x46: result.append(KeyEvent(code: .end, modifiers: mod)); return
    case 0x5A: result.append(KeyEvent(code: .tab, modifiers: .shift)); return
    default: break
    }

    // Sequences with trailing ~
    if final == 0x7E {
      // xterm modifyOtherKeys: CSI 27 ; <modifier> ; <key> ~
      if params.count >= 3, params[0] == 27, params[2] == 13 {
        result.append(KeyEvent(code: .enter, modifiers: modifiersFromParam(params[1])))
        return
      }
      // Alternate modified enter: CSI 13 ; <modifier> ~
      if params.count >= 2, params[0] == 13, params[1] != 0 {
        result.append(KeyEvent(code: .enter, modifiers: modifiersFromParam(params[1])))
        return
      }

      let code = params.first ?? 0
      switch code {
      case 1: result.append(KeyEvent(code: .home, modifiers: mod)); return
      case 2: result.append(KeyEvent(code: .insert, modifiers: mod)); return
      case 3: result.append(KeyEvent(code: .delete, modifiers: mod)); return
      case 4: result.append(KeyEvent(code: .end, modifiers: mod)); return
      case 5: result.append(KeyEvent(code: .pageUp, modifiers: mod)); return
      case 6: result.append(KeyEvent(code: .pageDown, modifiers: mod)); return
      case 11: result.append(KeyEvent(code: .f(1), modifiers: mod)); return
      case 12: result.append(KeyEvent(code: .f(2), modifiers: mod)); return
      case 13: result.append(KeyEvent(code: .f(3), modifiers: mod)); return
      case 14: result.append(KeyEvent(code: .f(4), modifiers: mod)); return
      case 15: result.append(KeyEvent(code: .f(5), modifiers: mod)); return
      case 17: result.append(KeyEvent(code: .f(6), modifiers: mod)); return
      case 18: result.append(KeyEvent(code: .f(7), modifiers: mod)); return
      case 19: result.append(KeyEvent(code: .f(8), modifiers: mod)); return
      case 20: result.append(KeyEvent(code: .f(9), modifiers: mod)); return
      case 21: result.append(KeyEvent(code: .f(10), modifiers: mod)); return
      case 23: result.append(KeyEvent(code: .f(11), modifiers: mod)); return
      case 24: result.append(KeyEvent(code: .f(12), modifiers: mod)); return
      default: break
      }
    }

    // CSI u (kitty keyboard protocol)
    if final == UInt8(ascii: "u") {
      guard let key = params.first else { return }
      let keyMod: Modifiers = params.count >= 2 ? modifiersFromParam(params[1]) : []
      if key == 13 {
        result.append(KeyEvent(code: .enter, modifiers: keyMod))
        return
      }
    }
  }

  private func parseSs3(final: UInt8) -> KeyEvent? {
    switch final {
    case 0x41: return KeyEvent(code: .up)
    case 0x42: return KeyEvent(code: .down)
    case 0x43: return KeyEvent(code: .right)
    case 0x44: return KeyEvent(code: .left)
    case 0x48: return KeyEvent(code: .home)
    case 0x46: return KeyEvent(code: .end)
    case 0x50: return KeyEvent(code: .f(1))
    case 0x51: return KeyEvent(code: .f(2))
    case 0x52: return KeyEvent(code: .f(3))
    case 0x53: return KeyEvent(code: .f(4))
    default: return nil
    }
  }

  private func modifiersFromParam(_ p: Int) -> Modifiers {
    var m = Modifiers()
    switch p {
    case 2: m.insert(.shift)
    case 3: m.insert(.alt)
    case 4:
      m.insert(.shift)
      m.insert(.alt)
    case 5: m.insert(.control)
    case 6:
      m.insert(.shift)
      m.insert(.control)
    case 7:
      m.insert(.alt)
      m.insert(.control)
    case 8:
      m.insert(.shift)
      m.insert(.alt)
      m.insert(.control)
    default: break
    }
    return m
  }
}
