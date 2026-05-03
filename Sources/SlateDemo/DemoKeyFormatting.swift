/// Human-readable labels for raw stdin chunks (one ``TerminalWakeEvent/stdinBytes`` at a time).
enum DemoKeyFormatting {
  static func describe(_ bytes: ContiguousArray<UInt8>) -> String {
    if bytes.isEmpty { return "" }
    let slice = ArraySlice(bytes)

    if let known = knownSequence(slice) {
      return known
    }

    if let utf8 = String(bytes: bytes, encoding: .utf8),
      !utf8.isEmpty,
      utf8.count <= 12,
      utf8.allSatisfy(\.isPrintableOrSpace)
    {
      return utf8.map { $0 == " " ? "␠" : String($0) }.joined()
    }

    return bytes.map(describeByte).joined()
  }

  private static func knownSequence(_ bytes: ArraySlice<UInt8>) -> String? {
    if bytes == [27] { return "Esc" }
    if bytes == [27, 91, 65] { return "↑" }
    if bytes == [27, 91, 66] { return "↓" }
    if bytes == [27, 91, 67] { return "→" }
    if bytes == [27, 91, 68] { return "←" }
    if bytes == [27, 91, 72] { return "Home" }
    if bytes == [27, 91, 70] { return "End" }
    if bytes == [27, 91, 53, 126] { return "PgUp" }
    if bytes == [27, 91, 54, 126] { return "PgDn" }
    if bytes == [127] || bytes == [8] { return "⌫" }
    if bytes == [9] { return "Tab" }
    if bytes == [10] || bytes == [13] { return "↵" }
    return nil
  }

  private static func describeByte(_ b: UInt8) -> String {
    switch b {
    case 9: return "Tab"
    case 10, 13: return "↵"
    case 127, 8: return "⌫"
    case 32...126:
      return String(UnicodeScalar(b))
    case 0...31:
      let c = Character(UnicodeScalar(64 &+ b))
      return "^\(c)"
    default:
      let h = String(b, radix: 16, uppercase: true)
      return "x" + (h.count == 1 ? "0" + h : h)
    }
  }
}

extension Character {
  fileprivate var isPrintableOrSpace: Bool {
    switch self {
    case " ", "\t", "\n", "\r": true
    default: unicodeScalars.allSatisfy { (32...126).contains($0.value) }
    }
  }
}
