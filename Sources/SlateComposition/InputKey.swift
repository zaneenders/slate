/// Text is reported as Unicode scalars, not grapheme clusters or display cells.
public enum InputKey: Equatable, Sendable {
  case scalar(Unicode.Scalar)
  /// A C0 control key, such as `.control(.c)` for Ctrl-C.
  /// Decoders prefer dedicated cases for Backspace, Tab, Enter and Escape.
  case control(ControlKey)
  case enter
  case tab
  case backspace
  case escape
  case up
  case down
  case right
  case left
  case home
  case end
  case insert
  case delete
  case pageUp
  case pageDown
  /// F1...F12. Decoders never emit a value outside this range.
  case function(UInt8)
}

/// Named C0 control bytes shared by macOS and Linux terminals. These describe
/// terminal input, not physical keys: Ctrl-Space, Ctrl-@ and Ctrl-2 can all
/// produce `.space`. Ctrl-H/I/J/M/[ overlap Backspace/Tab/Enter/Escape.
public enum ControlKey: UInt8, Equatable, Sendable {
  case space = 0x00
  case a = 0x01
  case b = 0x02
  case c = 0x03
  case d = 0x04
  case e = 0x05
  case f = 0x06
  case g = 0x07
  case h = 0x08
  case i = 0x09
  case j = 0x0a
  case k = 0x0b
  case l = 0x0c
  case m = 0x0d
  case n = 0x0e
  case o = 0x0f
  case p = 0x10
  case q = 0x11
  case r = 0x12
  case s = 0x13
  case t = 0x14
  case u = 0x15
  case v = 0x16
  case w = 0x17
  case x = 0x18
  case y = 0x19
  case z = 0x1a
  case leftBracket = 0x1b
  case backslash = 0x1c
  case rightBracket = 0x1d
  case caret = 0x1e
  case underscore = 0x1f
}

public struct KeyModifiers: OptionSet, Equatable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = Self(rawValue: 1)
  public static let alt = Self(rawValue: 2)
  public static let control = Self(rawValue: 4)
}
