public struct TerminalCellFlags: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let bold: Self = .init(rawValue: 1 << 0)
}
