import SlateCore

@main
@MainActor
enum SlateDemoEntry {

  static func main() async throws {
    let slate: Slate
    do {
      slate = try Slate()
    } catch {
      print("Failed setup")
      throw DemoError.failedSetup
    }

    final class DemoTranscript {
      var text = ""
    }

    let model = DemoTranscript()

    func draw() {
      slate.enscribe(
        grid: DemoFrameBuilder.makeGrid(
          cols: slate.cols,
          rows: slate.rows,
          transcript: model.text))
    }

    draw()

    await slate.start(prepare: { wake in
      // Background Timer tick
      Task { @MainActor in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(600))
          wake.requestRender()
        }
      }

      // Fake LLM Feed
      Task { @MainActor in
        let phrase =
          "Neville is a dog who streams tokens the way an LLM would feed your TUI. "
          + "Each chunk calls ExternalWake.requestRender() on the main actor. "
        let chunks = phrase.split(separator: " ").map { String($0) + " " }
        while !Task.isCancelled {
          for chunk in chunks {
            try? await Task.sleep(for: .milliseconds(240))
            model.text += chunk
            wake.requestRender()
          }
          model.text += "\n"
          wake.requestRender()
          try? await Task.sleep(for: .milliseconds(900))
        }
      }

    }) { event in
      switch event {
      case .resize:
        slate.refreshWindowSize()
      case .external: ()
      case .key(let byte):
        if shutdownRequested(forKey: byte) { return .stop }
      }
      draw()
      return .continue
    }
  }
}

enum DemoError: Error {
  case failedSetup
}

private func shutdownRequested(forKey byte: UInt8) -> Bool {
  switch byte {
  // ETX (Ctrl+C), EOT (Ctrl+D), or EOF sentinel from ``TerminalWakePump`` when stdin closes.
  case 3, 4, 0:
    true
  default:
    false
  }
}
