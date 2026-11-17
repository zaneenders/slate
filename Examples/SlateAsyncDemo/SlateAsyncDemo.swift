import Observation
import Slate

@MainActor @Observable private final class Counter {
  // Keep the macro's mutation helper nonthrowing under Slate's typed-throws checks.
  nonisolated func withMutation<Member, Result>(keyPath: KeyPath<Counter, Member>, _ mutation: () -> Result) -> Result {
    _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
  }
  var value = 0
  var paused = false
}

@main
struct SlateAsyncDemo: ScreenApplication {
  private let counter = Counter()

  static func main() async {
    var application = Self()
    let session = ScreenSession(maximumOutputBytes: 1_048_576, taskCapacity: 1)
    await session.main(
      application: &application, inputFileDescriptor: 0,
      outputFileDescriptor: 1, signalHandling: .managed)
  }

  mutating func start(in session: ScreenSession) {
    let counter = counter
    let accepted = session.startTask(at: 0) {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        if !counter.paused { counter.value &+= 1 }
      }
    }
    precondition(accepted)
  }

  func render(in size: TerminalSize) -> some Block {
    Column(gap: 1) {
      Text("Async updates", style: Style(foreground: .cyan, bold: true))
      Text("Count: \(counter.value)")
      Text(counter.paused ? "Paused" : "Running")
      Text("Space: pause / Q or Escape: quit", style: Style(dim: true))
    }.padding(1)
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(.character(" "), _):
      counter.paused.toggle()
      return .none
    case .key(.character("q"), _), .key(.escape, _), .key(.control(.c), _): return .quit
    case .key(.character("c"), let modifiers) where modifiers.withoutLocks == .control: return .quit
    default: return .none
    }
  }
}
