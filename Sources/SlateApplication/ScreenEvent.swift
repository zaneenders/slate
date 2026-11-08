public import SlateTerminal

/// A paste was rejected for invalid UTF-8 or incomplete terminal framing.
public enum PasteError: Error, Equatable, Sendable {
  case invalidUTF8
  case incomplete
}

/// One synchronous application event. Paste borrows the runner's validated
/// payload; the event cannot escape its callback or cross await.
/// Key modifiers are empty for ordinary input. Mouse coordinates are zero-based
/// terminal cells; reporting remains opt-in through configuration.mouseTracking.
public enum ScreenEvent: ~Escapable, ~Sendable {
  case key(InputKey, modifiers: KeyModifiers = [])
  case mouse(MouseEvent)
  case paste(UTF8Span)
  case pasteRejected(PasteError)
}
