import SlateCore

@main
enum SlateDemoEntry {
  static func main() async throws {
    var slate: Slate
    do {
      slate = try Slate()
    } catch {
      print("Failed setup")
      throw DemoError.failedSetup
    }

    final class DemoTranscript: @unchecked Sendable {
      var text = ""
    }

    let model = DemoTranscript()

    slate.enscribe(
      grid: DemoFrameBuilder.makeGrid(
        cols: slate.cols,
        rows: slate.rows,
        transcript: model.text))

    await slate.start(prepare: { wake in
      // Background Timer tick
      Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(33))
          wake.requestRender()
        }
      }

      // Fake LLM Feed
      Task {
        let phrase =
          "Neville is a dog who streams tokens the way an LLM would feed your TUI. "
          + "Each chunk calls ExternalWake.requestRender() from a background task. "
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

    }) { slate, event in
      switch event {
      case .resize:
        slate.refreshWindowSize()
      case .external: ()
      case .stdinBytes(let bytes):
        if bytes.isEmpty { return .stop }
        for byte in bytes {
          if shutdownRequested(forKey: byte) { return .stop }
        }
      }
      slate.enscribe(
        grid: DemoFrameBuilder.makeGrid(
          cols: slate.cols,
          rows: slate.rows,
          transcript: model.text))
      return .continue
    }
  }
}

enum DemoError: Error {
  case failedSetup
}

private func shutdownRequested(forKey byte: UInt8) -> Bool {
  switch byte {
  // ETX (Ctrl+C), EOT (Ctrl+D), or NUL from stdin in raw mode (EOF is an empty ``stdinBytes`` chunk).
  case 3, 4, 0:
    true
  default:
    false
  }
}
