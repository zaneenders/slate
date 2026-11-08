/// Framing events; bytes inside a paste are never interpreted as keys or replies.
public enum PasteEvent: Equatable, Sendable {
  case begin
  case byte(UInt8)
  case end
  case cancelled
}
