import Slate

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
import Musl
#endif

/// A visual debugger for the paged file reader. Indexing runs cooperatively
/// after the first terminal frame. Edits stay in a bounded memory overlay until
/// an explicit write streams the complete logical file to disk.
@main
struct SlateDocumentDemo: ScreenApplication {
  private enum Mode {
    case indexing(DocumentFileOpening)
    case file(DocumentFileViewer)
    case failure(String)
    case cancelled
  }
  private var mode: Mode
  private var lastIndexRedraw: ContinuousClock.Instant?

  var hasPendingWork: Bool {
    if case .indexing = mode { return true }
    if case .file(let viewer) = mode { return viewer.hasPendingWork }
    return false
  }

  var indexingProgress: FileIndexingProgress? {
    if case .indexing(let opening) = mode { return opening.progress }
    return nil
  }

  private static let usage = """
    Usage: document [--] path/to/file

    Example: swift run -c release document pi_hex_1b.txt

    Paged byte editor for regular files, including binary, with live page-cache diagnostics.
    Printable UTF-8 is shown with Unicode column widths; controls and malformed bytes appear as dots.
    Up/Down scroll rows; PgUp/PgDn page; 0-9 jump by file bytes; g/G start/end.
    [ ] jump disk pages; C clears Slate's cache; I toggles the inspector; ? helps; Q quits.
    Drag the scrollbar to seek; click its track to jump; the mouse wheel scrolls rows.
    Drag file text to select within its pane; y / Ctrl-C copies; Escape clears selection.
    / searches literal, case-sensitive UTF-8; Enter / n finds next and wraps; Tab switches focus; Escape closes.
    i inserts at the cursor or replaces a selection; type/paste to edit; Escape returns to browsing.
    In insert mode arrows move, Backspace/Delete erase, Home/End seek start/end, and Enter inserts LF.
    :w writes; :wq writes and quits; :q refuses unsaved edits; :q! discards them.
    :saveas path (or :w path) writes to a new name and switches to it, keeping the original file.
    Existing save-as destinations are never overwritten. Escape cancels an in-progress write before replacement.
    Unchanged bytes remain paged. Pending inserted text is limited to 1 MiB / 4,096 pieces; :w resets those limits.
    Indexing progress appears in the UI; Q / Escape / Ctrl-C cancels initial indexing.
    """

  static func main() {
    if CommandLine.arguments.count == 1 || (CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--help") {
      print(usage)
      return
    }
    _ = signal(SIGPIPE, SIG_IGN)
    var application = Self()
    if case .failure(let message) = application.mode { fail(message) }
    do throws(ScreenApplicationError) { try application.run(signalHandling: .managed) } catch {
      if case .interrupted(let number) = error { exit(128 + number) }
      fail("document: \(error)")
    }
    if case .failure(let message) = application.mode { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    let diagnostic = message + "\n"
    if let output = try? Output(fileDescriptor: STDERR_FILENO) {
      try? output.writeAll(diagnostic.utf8Span.span)
    }
    exit(EXIT_FAILURE)
  }

  init() {
    let arguments = CommandLine.arguments
    if arguments.count == 2 || (arguments.count == 3 && arguments[1] == "--") {
      self.init(path: arguments[arguments.count - 1])
    } else {
      self.init(mode: .failure(Self.usage))
    }
  }

  private init(mode: Mode) { self.mode = mode }

  init(path: String, configuration: FileDocumentConfiguration = .init()) {
    do {
      mode = .indexing(try DocumentFileOpening(path, configuration: configuration))
    } catch {
      mode = .failure(DocumentFileViewer.message(for: error) + " (\(error))")
    }
  }

  mutating func performPendingWork() -> ScreenUpdate {
    if case .file(let viewer) = mode { return viewer.performPendingWork() }
    guard case .indexing(let opening) = mode else { return .none }
    do throws(FileDocumentError) { try opening.advance() } catch {
      mode = .failure(DocumentFileViewer.message(for: error) + " (\(error))")
      return .redraw
    }
    if opening.isComplete {
      mode = .file(opening.finish())
      lastIndexRedraw = nil
      return .redraw
    }
    // Work can proceed every loop; terminal progress is limited to ~30 Hz.
    let now = ContinuousClock().now
    if let lastIndexRedraw, lastIndexRedraw.duration(to: now) < .milliseconds(33) { return .none }
    lastIndexRedraw = now
    return .redraw
  }

  static var configuration: ScreenApplicationConfiguration {
    .init(maximumSize: TerminalSize(columns: 160, rows: 60), mouseTracking: true)
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    if case .file(let viewer) = mode { return viewer.event(event, copyBuffer: &copyBuffer) }
    switch event {
    case .key(let key, let modifiers):
      guard Self.isQuitKey(key, modifiers: modifiers) else { return .none }
      if case .indexing = mode {
        mode = .cancelled  // Release the file and partial index immediately.
      }
      return .quit
    default: return .none
    }
  }

  private static func isQuitKey(_ key: InputKey, modifiers: KeyModifiers) -> Bool {
    key == .escape || key == .character("q") || key == .control(.q) || key == .control(.c)
      || (modifiers == .control && key == .character("c"))
  }

  func render(in size: TerminalSize) -> some Block {
    if case .file(let viewer) = mode { viewer.render(in: size) } else { Column {} }
  }

  func paint(in frame: inout Frame) {
    switch mode {
    case .indexing(let opening): opening.paint(in: &frame)
    case .file: break  // The viewer paints through its layout-owned canvas.
    case .failure(let message):
      frame.fill(frame.area, with: Cell(style: ViewerPalette.body))
      frame.text(message, in: frame.area, style: Style(foreground: .red))
      if frame.area.height > 2 {
        frame.text("Q / Escape: quit", in: Rect(y: 2, width: frame.area.width, height: 1))
      }
    case .cancelled: break
    }
  }
}
