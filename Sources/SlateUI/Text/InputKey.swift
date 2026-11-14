public enum InputKey: Equatable, Sendable {
  /// A character reported as one Unicode scalar, not a Swift Character grapheme.
  /// A grapheme cluster may arrive as several keys.
  case character(Unicode.Scalar)
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
  /// A named function key. The terminal decoder currently recognizes F1...F12.
  case function(FunctionKey)
}

/// Function keys F1...F35 from the Kitty keyboard protocol's functional key table.
/// Raw values are key numbers, not terminal escape sequence parameters.
/// https://sw.kovidgoyal.net/kitty/keyboard-protocol/#functional-key-definitions
public enum FunctionKey: UInt8, Equatable, Sendable {
  case f1 = 1
  case f2 = 2
  case f3 = 3
  case f4 = 4
  case f5 = 5
  case f6 = 6
  case f7 = 7
  case f8 = 8
  case f9 = 9
  case f10 = 10
  case f11 = 11
  case f12 = 12
  case f13 = 13
  case f14 = 14
  case f15 = 15
  case f16 = 16
  case f17 = 17
  case f18 = 18
  case f19 = 19
  case f20 = 20
  case f21 = 21
  case f22 = 22
  case f23 = 23
  case f24 = 24
  case f25 = 25
  case f26 = 26
  case f27 = 27
  case f28 = 28
  case f29 = 29
  case f30 = 30
  case f31 = 31
  case f32 = 32
  case f33 = 33
  case f34 = 34
  case f35 = 35
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
  /// The Super/Windows key on Linux and Command key on macOS.
  public static let `super` = Self(rawValue: 8)
  public static let command = Self.super
  public static let capsLock = Self(rawValue: 64)
  public static let numLock = Self(rawValue: 128)

  /// Modifiers used for shortcut matching, without Caps Lock or Num Lock state.
  /// Key events retain those lock bits so applications can inspect them.
  public var withoutLocks: Self { subtracting([.capsLock, .numLock]) }
}
