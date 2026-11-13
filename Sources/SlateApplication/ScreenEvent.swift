public import SlateTerminal

/// A paste was rejected for invalid UTF-8, incomplete terminal framing, or
/// exceeding the configured payload limit.
public enum PasteError: Error, Equatable, Sendable {
  case invalidUTF8
  case incomplete
  case tooLarge
}

/// One synchronous application event. Paste borrows the runner's validated
/// payload; the event cannot escape its callback or cross await.
/// Key modifiers are empty for ordinary input. Mouse coordinates are zero-based
/// terminal cells; reporting remains opt-in through configuration.mouseTracking.
public enum ScreenEvent: ~Escapable, ~Sendable {
  /// Elapsed time since the previous tick or the start of this interval,
  /// including scheduling delays. Missed ticks are skipped, never queued.
  case tick(elapsed: Duration)
  case key(InputKey, modifiers: KeyModifiers = [])
  case mouse(MouseEvent)
  case paste(UTF8Span)
  /// A zero-byte bracketed paste. Some terminals report image-only clipboard
  /// contents this way; Slate does not inspect the clipboard. Applications that
  /// support images can read a native clipboard when they receive this event.
  case pasteEmpty
  case pasteRejected(PasteError)
}
