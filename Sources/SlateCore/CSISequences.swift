/// Control Sequence Introducer fragments for terminal I/O and `RigidArray<UInt8>` encoding.
enum CSI {
  static let altOn = "\u{001b}[?1049h"
  static let altOff = "\u{001b}[?1049l"
  static let curHide = "\u{001b}[?25l"
  static let curShow = "\u{001b}[?25h"
  static let sgr0 = "\u{001b}[0m"
  static let clrHome = "\u{001b}[2J\u{001b}[1;1H"
  static let batchOff = "\u{001b}[?2026l"
  /// Bracketed paste **on**: terminal wraps pasted text in ``\e[200~`` / ``\e[201~`` so the
  /// decoder can distinguish a typed Enter (submit) from a pasted newline (literal).
  /// ``TerminalKeyDecoder`` already parses these markers as ``TerminalKeyEvent/bracketedPasteStart``
  /// / ``TerminalKeyEvent/bracketedPasteEnd``.
  static let bracketedPasteOn = "\u{001b}[?2004h"
  /// Bracketed paste **off** — pair with ``bracketedPasteOn`` on teardown.
  static let bracketedPasteOff = "\u{001b}[?2004l"

  // MARK: - Select graphic rendition (SGR)

  static let sgrBold = "\u{001b}[1m"
  /// Normal intensity (clears bold in common terminals).
  static let sgrNormalIntensity = "\u{001b}[22m"
  /// Faint / decreased intensity (SGR 2).
  static let sgrFaint = "\u{001b}[2m"

  /// Foreground truecolor `38;2` only (no trailing reset).
  static func sgrForeground(_ rgb: TerminalRGB) -> String {
    "\u{001b}[38;2;\(rgb.r);\(rgb.g);\(rgb.b)m"
  }

  /// Bold then foreground truecolor (common for emphasized colored text).
  static func sgrBoldForeground(_ rgb: TerminalRGB) -> String {
    sgrBold + sgrForeground(rgb)
  }

  /// Truecolor background `48;2` and foreground `38;2` for one cell (no trailing reset).
  static func sgrTruecolor(
    background: TerminalRGB,
    foreground: TerminalRGB
  ) -> String {
    sgrTruecolor(
      backgroundR: background.r, backgroundG: background.g, backgroundB: background.b,
      foregroundR: foreground.r, foregroundG: foreground.g, foregroundB: foreground.b)
  }

  /// Truecolor background `48;2` and foreground `38;2` for one cell (no trailing reset).
  static func sgrTruecolor(
    backgroundR: UInt8, backgroundG: UInt8, backgroundB: UInt8,
    foregroundR: UInt8, foregroundG: UInt8, foregroundB: UInt8
  ) -> String {
    "\u{001b}[48;2;\(backgroundR);\(backgroundG);\(backgroundB)m\u{001b}[38;2;\(foregroundR);\(foregroundG);\(foregroundB)m"
  }

  // MARK: - Cursor (CUP)

  /// Cursor position: **row** and **column** are **1-based** (ANSI CUP).
  static func cup(row rowOneBased: Int, column columnOneBased: Int) -> String {
    precondition(rowOneBased >= 1 && columnOneBased >= 1)
    return "\u{001b}[\(rowOneBased);\(columnOneBased)H"
  }
}
