import SlateTerminal

@testable import SlateApplication

@MainActor @discardableResult
func presentTestFrame<Application: ScreenApplication & ~Copyable>(
  runner: inout ScreenRunner, application: inout Application,
  actualSize: TerminalSize, to output: borrowing Output
) throws(ScreenError) -> Bool {
  guard let statistics = try runner.draw(application: &application, actualSize: actualSize, to: output) else {
    return false
  }
  application.didPresentFrame(statistics)
  return true
}
