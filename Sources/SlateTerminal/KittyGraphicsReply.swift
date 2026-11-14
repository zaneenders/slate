/// A bounded Kitty graphics acknowledgement, query result, or error. Parsing
/// borrows an already framed APC command; it never reads from the terminal.
/// The reply owns its inline message storage and can be retained by the caller.
public struct KittyGraphicsReply: Equatable, Sendable {
  public let imageID: UInt32
  public let placementID: UInt32?
  private let command: ApplicationCommand
  private let messageStart: Int

  /// Printable ASCII supplied by the terminal, including OK or an error code
  /// and detail. Long details retain their prefix and set messageTruncated.
  public var message: UTF8Span { unsafe UTF8Span(unchecked: command.bytes.extracting(messageStart...)) }
  public var messageTruncated: Bool { command.truncated }
  public var isSuccess: Bool {
    let bytes = command.bytes
    return !command.truncated && bytes.count - messageStart == 2
      && bytes[messageStart] == 0x4f && bytes[messageStart + 1] == 0x4b
  }

  /// Returns nil for unrelated commands, malformed headers, and invalid IDs.
  /// Keys may arrive in any order. Unknown keys are ignored for extensibility.
  public init?(_ command: ApplicationCommand) {
    let bytes = command.bytes
    guard bytes.count > 1 && bytes[0] == 0x47 else { return nil }
    var imageID: UInt32?
    var placementID: UInt32?
    var index = 1
    while index < bytes.count {
      let key = bytes[index]
      guard (65...90).contains(key) || (97...122).contains(key),
        index + 1 < bytes.count && bytes[index + 1] == 0x3d
      else { return nil }
      index += 2
      let start = index
      while index < bytes.count && bytes[index] != 0x2c && bytes[index] != 0x3b {
        guard (0x21...0x7e).contains(bytes[index]) else { return nil }
        index += 1
      }
      guard index > start && index < bytes.count else { return nil }
      if key == 0x69 || key == 0x70 {
        guard let value = kittyReplyNumber(bytes.extracting(start..<index)), value > 0 else { return nil }
        if key == 0x69 {
          guard imageID == nil else { return nil }
          imageID = value
        } else {
          guard placementID == nil else { return nil }
          placementID = value
        }
      }
      let delimiter = bytes[index]
      index += 1
      if delimiter == 0x3b { break }
    }
    guard let imageID, index < bytes.count && bytes[index - 1] == 0x3b else { return nil }
    for position in index..<bytes.count {
      guard (0x20...0x7e).contains(bytes[position]) else { return nil }
    }
    self.imageID = imageID
    self.placementID = placementID
    self.command = command
    messageStart = index
  }
}

private func kittyReplyNumber(_ bytes: Span<UInt8>) -> UInt32? {
  var value: UInt32 = 0
  for index in 0..<bytes.count {
    let digit = bytes[index]
    guard (0x30...0x39).contains(digit) else { return nil }
    let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: 10)
    let (next, addOverflow) = scaled.addingReportingOverflow(UInt32(digit - 0x30))
    guard !scaleOverflow && !addOverflow else { return nil }
    value = next
  }
  return value
}
