import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

// Child process for managed signal tests. Keep only the field state needed to
// verify that editing, paste, and clipboard operations survive intercepted signals.
@main
struct SlateSignalFixture: ScreenApplication {
  static func main() async {
    var application = Self()
    let session = ScreenSession(maximumOutputBytes: 1_048_576, taskCapacity: 0)
    await session.main(application: &application, inputFileDescriptor: 0, outputFileDescriptor: 1, signalHandling: .managed)
  }
  static var configuration: ScreenApplicationConfiguration { .init(enhancedKeyboard: true) }

  private let field = try! TextInput(capacity: 1_024)
  private var focused = false
  private var stressTeardown = false

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(let key, let modifiers): return handle(key, modifiers: modifiers, copyBuffer: &copyBuffer)
    case .paste(let text):
      guard focused else { return .none }
      do { try field.insert(text) } catch { return .quit }
      return .redraw
    case .pasteRejected: return .quit
    case .pasteEmpty: return .none
    case .mouse: return .none
    case .tick, .applicationCommand, .kittyGraphicsReply, .primaryDeviceAttributes: return .none
    }
  }

  private mutating func handle(
    _ key: InputKey, modifiers: KeyModifiers, copyBuffer: inout CopyBuffer
  ) -> ScreenUpdate {
    let modifiers = modifiers.withoutLocks
    if !focused && modifiers.isEmpty && (key == .character("!") || key == .character("@")) {
      stressTeardown = true
      // The second binding latches a cause before later teardown signals arrive.
      if key == .character("@") { deliverTestSignal(SIGTERM) }
      return .quit
    }
    let controlC = key == .control(.c) || (key == .character("c") && modifiers == .control)
    // Test-only binding: actual Ctrl-Z quits, including while editing.
    if key == .control(.z) || (key == .character("z") && modifiers == .control) {
      return .quit
    }
    if key == .tab, modifiers.isEmpty {
      focused.toggle()
      return .redraw
    }
    if key == .escape {
      focused = false
      return .redraw
    }
    if focused {
      switch field.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) {
      case .changed, .submit: return .redraw
      case .rejected: return .quit
      case .ignored: return controlC ? .quit : .none
      }
    }
    return controlC || (modifiers.isEmpty && key == .character("q")) ? .quit : .none
  }

  func render(in size: TerminalSize) -> some Block {
    InputBox(field, focused: focused)
  }

  mutating func clearGraphics(to output: borrowing Output) throws(KittyGraphicsError) {
    guard stressTeardown else { return }
    stressTeardown = false
    var mask = sigset_t()
    precondition(unsafe pthread_sigmask(SIG_SETMASK, nil, &mask) == 0)
    precondition(unsafe sigismember(&mask, SIGUSR1) == 1)
    precondition(unsafe sigismember(&mask, SIGTERM) == 1)
    for _ in 0..<1_024 {
      deliverTestSignal(SIGUSR1)
      deliverTestSignal(SIGTTIN)
      deliverTestSignal(SIGTTOU)
      deliverTestSignal(SIGPIPE)
    }
    do throws(IOError) {
      try output.writeAll("teardown complete".utf8Span.span)
    } catch { throw .output(error) }
  }
}

// Async main's executor may inherit a blocked signal mask. Deliver test raises synchronously within one callback.
private func deliverTestSignal(_ number: Int32) {
  var set = sigset_t()
  var saved = sigset_t()
  precondition(unsafe sigemptyset(&set) == 0)
  precondition(unsafe sigaddset(&set, number) == 0)
  precondition(unsafe pthread_sigmask(SIG_UNBLOCK, &set, &saved) == 0)
  defer { _ = unsafe pthread_sigmask(SIG_SETMASK, &saved, nil) }
  _ = raise(number)
}
