/// Synchronous state machine that converts raw bytes from a TTY into ``KeyEvent`` values.
///
/// Handles:
/// - UTF-8 multi-byte sequences.
/// - ANSI escape sequences (arrows, function keys, etc.).
/// - ASCII control characters (`Ctrl+C` = byte `0x03`).
public struct EscapeParser: Sendable {
  private enum State: Sendable {
    case ground
    case escape
    case csi
    case csiParam
    case ss3
    case utf8Remaining(count: Int, codepoint: UInt32)
  }

  private var state: State
  private var paramBuffer: [UInt8]

  public init() {
    self.state = .ground
    self.paramBuffer = []
  }

  /// Feed one byte. Returns a ``KeyEvent`` when a complete sequence has been parsed.
  public mutating func feed(_ byte: UInt8) -> KeyEvent? {
    switch state {
    case .ground:
      return feedGround(byte)
    case .escape:
      return feedEscape(byte)
    case .csi:
      return feedCsi(byte)
    case .csiParam:
      return feedCsiParam(byte)
    case .ss3:
      return feedSs3(byte)
    case .utf8Remaining(let count, let codepoint):
      return feedUtf8(byte, remaining: count, codepoint: codepoint)
    }
  }

  // MARK: - States

  private mutating func feedGround(_ byte: UInt8) -> KeyEvent? {
    if byte == 0x1B {
      state = .escape
      return nil
    }

    // DEL (0x7F) is treated as backspace
    if byte == 0x7F {
      return KeyEvent(code: .backspace)
    }

    // Control characters (0x00–0x1F, excluding ESC which is handled above)
    if byte < 0x20 {
      return parseControl(byte)
    }

    // ASCII printable
    if byte < 0x80 {
      let scalar = Unicode.Scalar(byte)
      return KeyEvent(code: .character(Character(scalar)))
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
    return nil
  }

  private mutating func feedEscape(_ byte: UInt8) -> KeyEvent? {
    if byte == 0x5B {  // [
      state = .csi
      return nil
    }
    if byte == 0x4F {  // O
      state = .ss3
      return nil
    }
    // ESC + char → Alt+char
    state = .ground
    let scalar = Unicode.Scalar(byte)
    if scalar.isASCII {
      return KeyEvent(code: .character(Character(scalar)), modifiers: .alt)
    }
    return nil
  }

  private mutating func feedCsi(_ byte: UInt8) -> KeyEvent? {
    paramBuffer.removeAll()
    if byte >= 0x30 && byte <= 0x3F {
      paramBuffer.append(byte)
      state = .csiParam
      return nil
    }
    // No parameters; final byte follows immediately.
    let result = parseCsi(params: [], final: byte)
    state = .ground
    return result
  }

  private mutating func feedCsiParam(_ byte: UInt8) -> KeyEvent? {
    if byte >= 0x30 && byte <= 0x3F {
      paramBuffer.append(byte)
      return nil
    }
    if byte >= 0x20 && byte <= 0x2F {
      // Intermediate byte (ignored for initial implementation).
      paramBuffer.append(byte)
      return nil
    }
    // Final byte
    let params = parseCsiParams(paramBuffer)
    let result = parseCsi(params: params, final: byte)
    state = .ground
    paramBuffer.removeAll()
    return result
  }

  private mutating func feedSs3(_ byte: UInt8) -> KeyEvent? {
    state = .ground
    return parseSs3(final: byte)
  }

  private mutating func feedUtf8(_ byte: UInt8, remaining: Int, codepoint: UInt32) -> KeyEvent? {
    let newCodepoint = (codepoint << 6) | UInt32(byte & 0x3F)
    if remaining == 1 {
      state = .ground
      if let scalar = Unicode.Scalar(newCodepoint) {
        return KeyEvent(code: .character(Character(scalar)))
      }
      return nil
    }
    state = .utf8Remaining(count: remaining - 1, codepoint: newCodepoint)
    return nil
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
    case 0x0A: return KeyEvent(code: .enter)
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

  private func parseCsi(params: [Int], final: UInt8) -> KeyEvent? {
    let mod: Modifiers
    if params.count >= 2, params[0] == 1 {
      mod = modifiersFromParam(params[1])
    } else {
      mod = []
    }

    switch final {
    case 0x41: return KeyEvent(code: .up, modifiers: mod)
    case 0x42: return KeyEvent(code: .down, modifiers: mod)
    case 0x43: return KeyEvent(code: .right, modifiers: mod)
    case 0x44: return KeyEvent(code: .left, modifiers: mod)
    case 0x48: return KeyEvent(code: .home, modifiers: mod)
    case 0x46: return KeyEvent(code: .end, modifiers: mod)
    case 0x5A: return KeyEvent(code: .tab, modifiers: .shift)
    default: break
    }

    // Sequences with trailing ~
    if final == 0x7E {
      let code = params.first ?? 0
      switch code {
      case 1: return KeyEvent(code: .home, modifiers: mod)
      case 2: return KeyEvent(code: .insert, modifiers: mod)
      case 3: return KeyEvent(code: .delete, modifiers: mod)
      case 4: return KeyEvent(code: .end, modifiers: mod)
      case 5: return KeyEvent(code: .pageUp, modifiers: mod)
      case 6: return KeyEvent(code: .pageDown, modifiers: mod)
      case 11: return KeyEvent(code: .f(1), modifiers: mod)
      case 12: return KeyEvent(code: .f(2), modifiers: mod)
      case 13: return KeyEvent(code: .f(3), modifiers: mod)
      case 14: return KeyEvent(code: .f(4), modifiers: mod)
      case 15: return KeyEvent(code: .f(5), modifiers: mod)
      case 17: return KeyEvent(code: .f(6), modifiers: mod)
      case 18: return KeyEvent(code: .f(7), modifiers: mod)
      case 19: return KeyEvent(code: .f(8), modifiers: mod)
      case 20: return KeyEvent(code: .f(9), modifiers: mod)
      case 21: return KeyEvent(code: .f(10), modifiers: mod)
      case 23: return KeyEvent(code: .f(11), modifiers: mod)
      case 24: return KeyEvent(code: .f(12), modifiers: mod)
      default: break
      }
    }

    return nil
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
