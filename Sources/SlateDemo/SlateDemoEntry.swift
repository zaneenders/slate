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

    final class DemoModel {
      var transcript = ""
      private(set) var keyPressCount = 0
      /// Recent stdin chunks (one entry per read), newest last.
      private(set) var keyEvents: [String] = []
      private let maxKeyEvents = 10

      func recordKeyChunk(_ bytes: ContiguousArray<UInt8>) {
        let summary = DemoKeyFormatting.describe(bytes)
        guard !summary.isEmpty else { return }
        keyPressCount += 1
        keyEvents.append(summary)
        if keyEvents.count > maxKeyEvents {
          keyEvents.removeFirst(keyEvents.count &- maxKeyEvents)
        }
      }

      var keyHistoryLine: String {
        keyEvents.joined(separator: " · ")
      }
    }

    let model = DemoModel()

    slate.enscribe(
      grid: DemoFrameBuilder.makeGrid(
        cols: slate.cols,
        rows: slate.rows,
        transcript: model.transcript,
        keyHistoryLine: model.keyHistoryLine,
        keyPressCount: model.keyPressCount))

    await slate.start(prepare: { wake in
      // Background Timer tick
      Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(33))
          wake.requestRender()
        }
      }

      // Neville nonsense, streamed one word at a time for the transcript box.
      Task {
        let phrase =
          "Neville spotted the squirrel and the living room became a blur of righteous fury. "
          + "Every couch cushion was collateral damage in service of the one true cause. "
          + "He launched through the drapes like a guided missile with bad legal counsel. "
          + "There was one loud crunch of glass and silence except for a very pleased tail. "
          + "The squirrel sat outside on the fence delivering what can only be called mockery. "
          + "Neville stood amid the shards with pride; the window was open to justice now. "
        let chunks = phrase.split(separator: " ").map { String($0) + " " }
        while !Task.isCancelled {
          for chunk in chunks {
            try? await Task.sleep(for: .milliseconds(240))
            model.transcript += chunk
            wake.requestRender()
          }
          model.transcript += "\n"
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
        var stop = false
        for byte in bytes {
          if shutdownRequested(forKey: byte) { stop = true }
        }
        if !stop { model.recordKeyChunk(bytes) }
        if stop { return .stop }
      }
      slate.enscribe(
        grid: DemoFrameBuilder.makeGrid(
          cols: slate.cols,
          rows: slate.rows,
          transcript: model.transcript,
          keyHistoryLine: model.keyHistoryLine,
          keyPressCount: model.keyPressCount))
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
