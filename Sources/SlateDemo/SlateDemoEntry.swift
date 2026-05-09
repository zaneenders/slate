import SlateCore
import ProfileRecorderServer
import Logging

@main
enum SlateDemoEntry {
  static func main() async throws {
    // In-process sampling profiler — activate by setting an env var:
    //   PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/slate-samples-{PID}.sock' swift run -c release SlateDemo
    // Then collect samples:
    //   curl -sd '{"numberOfSamples":500,"timeInterval":"10 ms"}' --unix-socket /tmp/slate-samples-PID.sock http://unix/sample | swift demangle --simplified > /tmp/samples.perf
    // Drag /tmp/samples.perf onto https://speedscope.app or https://profiler.firefox.com
    async let _ = ProfileRecorderServer(configuration: .parseFromEnvironment())
      .runIgnoringFailures(logger: Logger(label: "slate-profiler"))

    var slate: Slate
    do {
      slate = try Slate()
    } catch {
      print("Failed setup")
      throw DemoError.failedSetup
    }

    final class DemoState {
      var grid: TerminalCellGrid
      var input = TerminalInputHandler()
      var transcript: [(speaker: String, text: String)] = []
      var streamingText = ""
      var keyHistory: [String] = []
      var keyCount = 0
      /// Absolute index of the top wrapped transcript row in the viewport. Kept in sync by
      /// the renderer (which clamps it against the current wrap geometry) so handlers can
      /// just nudge it without knowing the row count.
      var transcriptFirstVisibleRow = 0
      /// When true, the viewport always shows the live tail. When false, ``transcriptFirstVisibleRow``
      /// pins the top of the viewport so streaming tokens at the bottom don't drag the user's
      /// scrolled-up position. The renderer flips this back to true automatically when the
      /// user scrolls down to the live tail.
      var followingLiveTranscript = true
      private let maxKeyHistory = 12

      init(cols: Int, rows: Int) {
        grid = DemoFrameBuilder.makeGrid(cols: cols, rows: rows)
      }

      func resize(cols: Int, rows: Int) {
        guard grid.cols != cols || grid.rows != rows else { return }
        let fill = TerminalCell(
          glyph: " ",
          foreground: TerminalRGB(r: 195, g: 205, b: 220),
          background: TerminalRGB(r: 14, g: 14, b: 24),
          flags: [])
        grid.resize(cols: cols, rows: rows, filling: fill)
        // Wrap geometry changed; snap to live tail so the user isn't left at a stale row.
        followingLiveTranscript = true
      }

      func recordKey(_ action: TerminalInputAction) {
        let label = DemoKeyFormatting.describe(action)
        guard !label.isEmpty else { return }
        keyCount &+= 1
        keyHistory.append(label)
        if keyHistory.count > maxKeyHistory {
          keyHistory.removeFirst(keyHistory.count &- maxKeyHistory)
        }
      }

      func enscribe(slate: inout Slate) {
        DemoFrameBuilder.render(
          into: &grid,
          cols: slate.cols,
          rows: slate.rows,
          transcript: transcript,
          streamingText: streamingText,
          inputBuffer: input.buffer,
          keyHistory: keyHistory,
          keyCount: keyCount,
          firstVisibleRow: &transcriptFirstVisibleRow,
          followingLiveTranscript: &followingLiveTranscript)
        slate.enscribe(grid: &grid)
      }
    }

    let state = DemoState(cols: slate.cols, rows: slate.rows)
    state.enscribe(slate: &slate)

    await slate.start(prepare: { wake in
      // Stream Neville's thoughts word-by-word, rotating through topics.
      Task {
        let thoughts: [String] = [
          "The steak smells like it was made specifically for me. They say no every time. They are wrong. I will try again at dinner.",
          "Eye contact with the squirrel. Unacceptable. I launched through the screen door. The squirrel was gone. The door is still a problem.",
          "Saw the yard through the glass. Walked into the window at full speed. The glass is still there. Investigation ongoing.",
          "Seven couch positions. I rotate every thirty minutes for optimal readiness. This is not napping. Do not disturb me.",
          "They put vegetables in my bowl. Next to the kibble. I looked at them for a long time. I am still looking at them.",
          "The socks were on the floor. They smelled interesting. I carried one to a different room. This felt correct.",
        ]
        var thoughtIndex = 0

        while !Task.isCancelled {
          let thought = thoughts[thoughtIndex % thoughts.count]
          thoughtIndex &+= 1
          let words = thought.split(separator: " ").map { String($0) + " " }

          for word in words {
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
            state.streamingText += word
            wake.requestRender()
          }
          let completed = state.streamingText.trimmingCharacters(in: .whitespaces)
          state.transcript.append((speaker: "Neville", text: completed))
          state.streamingText = ""
          wake.requestRender()
          try? await Task.sleep(for: .milliseconds(900))
        }
      }
    }) { slate, event in
      switch event {
      case .resize:
        slate.refreshWindowSize()
        state.resize(cols: slate.cols, rows: slate.rows)

      case .external:
        break

      case .stdinBytes(let bytes):
        if bytes.isEmpty { return .stop }
        var shouldStop = false

        for action in state.input.handle(bytes) {
          switch action {
          case .ctrlC, .ctrlD:
            shouldStop = true
          case .enter:
            let text = state.input.takeBuffer()
            if !text.isEmpty {
              state.transcript.append((speaker: "you", text: text))
              state.followingLiveTranscript = true
            }
            state.recordKey(action)
          case .arrowUp:
            state.transcriptFirstVisibleRow -= 1
            state.followingLiveTranscript = false
            state.recordKey(action)
          case .arrowDown:
            state.transcriptFirstVisibleRow += 1
            state.followingLiveTranscript = false
            state.recordKey(action)
          case .pageUp:
            state.transcriptFirstVisibleRow -= DemoFrameBuilder.pageScrollLines
            state.followingLiveTranscript = false
            state.recordKey(action)
          case .pageDown:
            state.transcriptFirstVisibleRow += DemoFrameBuilder.pageScrollLines
            state.followingLiveTranscript = false
            state.recordKey(action)
          case .home:
            state.transcriptFirstVisibleRow = 0
            state.followingLiveTranscript = false
            state.recordKey(action)
          case .end:
            state.followingLiveTranscript = true
            state.recordKey(action)
          default:
            state.recordKey(action)
          }
        }
        if shouldStop { return .stop }
      }

      state.enscribe(slate: &slate)
      return .continue
    }
  }
}

enum DemoError: Error {
  case failedSetup
}
