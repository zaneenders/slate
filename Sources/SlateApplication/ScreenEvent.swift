public import SlateTerminal

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
