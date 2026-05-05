/// A decoded terminal key press (or paste boundary) decoded from raw stdin bytes.
public enum TerminalKeyEvent: Sendable, Equatable {
  case character(Character)  // printable Unicode or space
  case enter
  /// Shift+Enter (CSI u kitty: `\e[13;2u`; xterm: `\e[27;2;13~`; alternate: `\e[13;2~`).
  case shiftEnter
  case backspace
  case delete  // \e[3~
  case tab
  case escape
  case arrowUp, arrowDown, arrowLeft, arrowRight
  case pageUp, pageDown
  case home, end
  /// Raw control byte (1–31, excluding backspace/tab/enter/escape).
  case ctrl(UInt8)
  case bracketedPasteStart
  case bracketedPasteEnd
  case unknown(ContiguousArray<UInt8>)
}

/// Stateful stdin decoder: handles UTF-8 multibyte sequences split across chunks and CSI escape
/// sequences. Create one instance per input stream and call ``decode(_:emit:)`` for each
/// ``TerminalWakeEvent/stdinBytes(_:)`` chunk. Call ``flush(emit:)`` on teardown to drain any
/// buffered lone ESC.
public struct TerminalKeyDecoder: Sendable {
  private var overflow: ContiguousArray<UInt8> = []
  private var utf8Staging: ContiguousArray<UInt8> = []

  public init() {}

  /// Decode one stdin chunk, emitting zero or more ``TerminalKeyEvent`` values in order.
  public mutating func decode(
    _ bytes: ContiguousArray<UInt8>,
    emit: (TerminalKeyEvent) -> Void
  ) {
    var all = overflow
    all.append(contentsOf: bytes)
    overflow.removeAll(keepingCapacity: true)
    processBytes(all, emit: emit)
  }

  /// Flush any buffered state (lone ESC, incomplete UTF-8). Call on teardown.
  public mutating func flush(emit: (TerminalKeyEvent) -> Void) {
    if overflow == [0x1B] {
      overflow.removeAll(keepingCapacity: true)
      emit(.escape)
    } else if !overflow.isEmpty {
      let o = overflow
      overflow.removeAll(keepingCapacity: true)
      emit(.unknown(o))
    }
    flushUTF8(emit: emit)
  }

  // MARK: - Private

  private mutating func processBytes(
    _ all: ContiguousArray<UInt8>,
    emit: (TerminalKeyEvent) -> Void
  ) {
    var i = all.startIndex
    while i < all.endIndex {
      let b = all[i]

      if b == 0x1B {
        flushUTF8(emit: emit)
        if i + 1 >= all.endIndex {
          // Lone ESC at end of chunk — buffer until next chunk.
          overflow.append(0x1B)
          i += 1
          continue
        }
        if all[i + 1] == 0x5B {  // ESC[  → CSI
          var j = i + 2
          while j < all.endIndex && !isCSIFinal(all[j]) { j += 1 }
          if j >= all.endIndex {
            overflow.append(contentsOf: all[i...])
            return
          }
          let params = ContiguousArray(all[(i + 2)..<j])
          emitCSI(params: params, terminator: all[j], emit: emit)
          i = j + 1
        } else {
          emit(.escape)
          i += 1
        }
        continue
      }

      switch b {
      case 8, 127:
        flushUTF8(emit: emit)
        emit(.backspace)
      case 9:
        flushUTF8(emit: emit)
        emit(.tab)
      case 10, 13:
        flushUTF8(emit: emit)
        emit(.enter)
      case 1...31:
        flushUTF8(emit: emit)
        emit(.ctrl(b))
      case 32...126:
        flushUTF8(emit: emit)
        emit(.character(Character(UnicodeScalar(b))))
      default:
        utf8Staging.append(b)
        tryDecodeUTF8(partial: true, emit: emit)
      }
      i += 1
    }
    tryDecodeUTF8(partial: true, emit: emit)
  }

  private mutating func tryDecodeUTF8(partial: Bool, emit: (TerminalKeyEvent) -> Void) {
    while !utf8Staging.isEmpty {
      let first = utf8Staging[0]
      let need: Int
      if first & 0xE0 == 0xC0 {
        need = 2
      } else if first & 0xF0 == 0xE0 {
        need = 3
      } else if first & 0xF8 == 0xF0 {
        need = 4
      } else {
        utf8Staging.removeFirst()
        emit(.character("\u{FFFD}"))
        continue
      }

      if utf8Staging.count < need {
        if partial { break }
        utf8Staging.removeFirst()
        emit(.character("\u{FFFD}"))
        continue
      }

      let slice = Array(utf8Staging.prefix(need))
      if let s = String(bytes: slice, encoding: .utf8), let ch = s.first {
        utf8Staging.removeFirst(need)
        emit(.character(ch))
      } else {
        utf8Staging.removeFirst()
        emit(.character("\u{FFFD}"))
      }
    }
  }

  private mutating func flushUTF8(emit: (TerminalKeyEvent) -> Void) {
    tryDecodeUTF8(partial: false, emit: emit)
    if !utf8Staging.isEmpty {
      let bad = utf8Staging
      utf8Staging.removeAll(keepingCapacity: true)
      emit(.unknown(bad))
    }
  }

  private func isCSIFinal(_ b: UInt8) -> Bool {
    b >= 0x40 && b <= 0x7E
  }

  private func emitCSI(
    params: ContiguousArray<UInt8>,
    terminator: UInt8,
    emit: (TerminalKeyEvent) -> Void
  ) {
    if params.isEmpty {
      switch terminator {
      case 0x41: emit(.arrowUp)
      case 0x42: emit(.arrowDown)
      case 0x43: emit(.arrowRight)
      case 0x44: emit(.arrowLeft)
      case 0x48: emit(.home)
      case 0x46: emit(.end)
      default:
        emit(.unknown(ContiguousArray([0x1B, 0x5B, terminator])))
      }
      return
    }

    let paramStr = String(bytes: Array(params), encoding: .utf8) ?? ""
    let ints = paramStr.split(separator: ";").compactMap { Int($0) }

    // CSI u — kitty keyboard protocol: `\e[code;modifiersu`.
    // Non-zero modifier means a modified key; modifier 1 = unshifted (same as plain).
    if terminator == 0x75 {
      if let key = ints.first, key == 13, ints.count >= 2, ints[1] != 1 {
        emit(.shiftEnter)
      } else {
        var full: ContiguousArray<UInt8> = [0x1B, 0x5B]
        full.append(contentsOf: params)
        full.append(0x75)
        emit(.unknown(full))
      }
      return
    }

    if terminator == 0x7E {
      // xterm-style `\e[27;modifier;13~` (Shift+Enter is modifier 2).
      if ints.count >= 3, ints[0] == 27, ints[2] == 13, ints[1] != 1 {
        emit(.shiftEnter)
        return
      }
      // Alternate `\e[13;modifier~`.
      if ints.count >= 2, ints[0] == 13, ints[1] != 1 {
        emit(.shiftEnter)
        return
      }
      switch paramStr {
      case "3": emit(.delete)
      case "5": emit(.pageUp)
      case "6": emit(.pageDown)
      case "200": emit(.bracketedPasteStart)
      case "201": emit(.bracketedPasteEnd)
      default:
        var full: ContiguousArray<UInt8> = [0x1B, 0x5B]
        full.append(contentsOf: params)
        full.append(0x7E)
        emit(.unknown(full))
      }
      return
    }

    var full: ContiguousArray<UInt8> = [0x1B, 0x5B]
    full.append(contentsOf: params)
    full.append(terminator)
    emit(.unknown(full))
  }
}
