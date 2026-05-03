public enum KeyCode: Equatable, Sendable {
  case character(Character)
  case f(Int)
  case up, down, left, right
  case home, end, pageUp, pageDown
  case insert, delete
  case enter, tab, backspace, escape
  case scrollUp, scrollDown
}

public struct Modifiers: OptionSet, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let shift = Modifiers(rawValue: 1 << 0)
  public static let control = Modifiers(rawValue: 1 << 1)
  public static let alt = Modifiers(rawValue: 1 << 2)
}

public struct KeyEvent: Sendable {
  public var code: KeyCode
  public var modifiers: Modifiers

  public init(code: KeyCode, modifiers: Modifiers = []) {
    self.code = code
    self.modifiers = modifiers
  }
}
