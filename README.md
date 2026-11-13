# Slate

A Swift terminal graphics library with composable layout, Unicode cells, custom
drawing, and ANSI frame diffing. Requires Swift 6.4.2; the macOS target is 27.

Start with the small interactive example:

```sh
swift run slate-starter
```

[SlateStarter.swift](Examples/SlateStarter/SlateStarter.swift) is the intended
starting point for a new application: a text input, a submitted message, and an
event handler. Type or paste into the input and press **Enter** to display the
text in the second field. Further edits update that field only after another
Enter. **Escape** or **Ctrl-C** quits; **q** is ordinary input.
Edit `render` to change the screen and `event` to change how it responds to input.
Return `.redraw` after changing state, `.none` when nothing changes, or `.quit`
to exit. Slate handles terminal setup, cleanup, and resizing.

Run the larger graphics showcase:

```sh
swift run -c release slate-graphics-demo
```

Drag the floating panel by its title bar with the left mouse button. It stays
inside the viewport and remembers its position when reopened. **O** toggles the
panel, **Escape** closes it, **Space** pauses the bars, and **Q** quits. Resize
the terminal to see the layout adapt. Animation advances on 16 ms ticks and drops
missed ticks instead of accumulating work.

## Custom drawing

Create a drawing owner once, then compose `Canvas(owner)` with ordinary blocks.
The canvas fills its available space; `frame`, `padding`, and `border` constrain
its drawing region. Coordinates start at zero inside that region.

```swift
import Slate

final class Bars: CanvasDrawing {
  func paint(in frame: inout Frame) {
    for row in 0..<frame.area.height {
      let width = (row + 1) * frame.area.width / frame.area.height
      frame.fill(
        Rect(y: row, width: width, height: 1),
        with: Cell(style: Style(background: .cyan)))
    }
  }
}

@main
struct Demo: ScreenApplication {
  private let bars = Bars()

  func render(in size: TerminalSize) -> some Block {
    Column(gap: 1) {
      Text("Slate — press q to quit")
      Canvas(bars).border("Custom drawing").frame(width: .fill, height: .fill)
    }.padding(1)
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    if case .key(.character("q"), _) = event { return .quit }
    return .none
  }
}
```

`Surface` owns the cell grid and layout storage independently of terminal I/O.
`Frame` borrows those cells for synchronous drawing. `Screen` presents full-screen
ANSI diffs; `ScreenRegion` presents a positioned region. `ScreenApplication`
provides the input loop and terminal-mode lifecycle.

Applications receive `.tick(elapsed:)` events every 50 ms by default. Override
`tickInterval` to change the interval or return `nil` to disable ticks:

```swift
var tickInterval: Duration? { isPaused ? nil : .milliseconds(16) }

mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
  switch event {
  case .tick(let elapsed):
    animation.advance(by: elapsed)
    return .redraw
  default: return .none
  }
}
```

The runner owns scheduling. Changing the interval or resuming a suspended session
starts a fresh interval; intervals must be positive. Elapsed time includes delays,
and a late iteration delivers one tick rather than catching up missed updates.
Polling rounds up to whole milliseconds, and callbacks or I/O can delay delivery.
Ticks request no rendering unless the handler returns `.redraw`. Pending work
remains independent: use `hasPendingWork` and `performPendingWork()` for bounded
cooperative processing, such as indexing a file.

## Layers

`Overlay` places children in the same rectangle and paints them in source order,
back to front. Fit-sized children keep their natural size; fill-sized children
use the available region. All nine edge/center alignments are supported.

```swift
Overlay(alignment: .center) {
  Canvas(backgroundDrawing)
  Text("Connected")
    .padding(1).border().background(.rgb(22, 30, 45))
}.frame(width: .fill, height: .fill)
```

Untouched cells reveal earlier layers; an explicit background makes a panel
opaque. Layers share one grid, using one ordinary layout node per container
and no extra cell buffers. Drawing cost scales with the cells painted across
all layers. Removing a layer restores the underlying composition next frame.

Use `.position(column:row:)` for a layer's top-left corner in parent-local cells:

```swift
Overlay {
  Canvas(backgroundDrawing)
  Text("Move me").padding(1).border("Panel")
    .background(.rgb(22, 30, 45)).position(column: 8, row: 3)
}.frame(width: .fill, height: .fill)
```

Coordinates must be `0...65_535`. Content keeps its requested size, clipped to
the parent; its origin is clamped so it stays inside. The position wrapper fills
its layout slot and adds one node without allocating another grid. Applications
own mouse handling: enable `mouseTracking` in the configuration and handle
`.mouse` events. The showcase uses one startup-owned drag state with no event
queue, preserving the grab offset and cancelling capture on hide or resize.

## Colors and terminal settings

Use `Color.rgb(red, green, blue)` with byte channels for explicit color. Select
the output policy at initialization:

```swift
static var configuration: ScreenApplicationConfiguration {
  .init(capabilities: .init(color: .trueColor, unicode: .grapheme))
}
```

`Screen` and `ScreenRegion` accept the same `capabilities` argument.

| Color mode | Output |
| --- | --- |
| `.trueColor` | RGB colors and existing palette entries |
| `.indexed256` (default) | RGB mapped to the nearest xterm color-cube or gray entry |
| `.ansi16` | Standard/bright ANSI colors, using a canonical palette for RGB fallback |
| `.monochrome` | Default foreground/background, retaining text attributes |

Customized terminal palettes may differ from the fallback palette. Settings are
explicit; Slate does not inspect environment variables or probe the terminal.
The default `.grapheme` policy uses Slate's Unicode widths and lets
`ScreenApplication` manage mode 2027. Choose `.ascii` for ASCII-only output:
non-ASCII glyphs become `?` (plus a space for two-column glyphs), preserving
layout columns without enabling mode 2027. Manual Unicode presenters coordinate
their own `output.graphemeClustering()` scope.

## Bounds and costs

- Allocate drawing owners and reusable buffers before rendering. Canvas stores
  a class-bound reference, avoiding per-frame closure contexts and boxed values.
  Allocation guarantees apply to warmed, successful release-mode rendering;
  debug builds and error propagation may allocate.
- Layout uses `UniqueArray` storage, starting at 64 nodes and doubling on demand
  without a node limit. Depth remains limited to 32. Applications need no capacity
  setting. Growth is an explicit allocation exception; smaller frames and failed
  layouts retain capacity for reuse. `nodeCapacity` reports the current capacity.
  Canvas shares the drawing table with input fields; its payload costs 16 bytes
  per node on 64-bit hosts. `storageBudgetBytes` reports current retained storage.
  Layout memory scales with retained capacity times the node/drawing strides;
  doubling temporarily needs at most 1.5 times the new payload during growth.
  Layout work scales with node count, including offscreen and empty blocks;
  applications own the size and processing cost of their block lists.
- Drawing runs once per nonempty canvas, in block order, after successful layout.
  Viewport or layout failure preserves the last frame and releases temporary references.
- Each canvas borrows the existing grid: no extra cell buffer or copying. Writes
  clip to its local area. Overwriting half an existing wide glyph also blanks its
  other half, even across the clip edge, while preserving the neighboring style.
- Bracketed paste retains at most `ScreenApplicationConfiguration.maximumPasteBytes`
  (1 MiB by default, 64 MiB maximum). Oversized pastes are drained through their
  terminator and reported as `.pasteRejected(.tooLarge)`, so their tail never
  becomes keystrokes. Empty bracketed pastes are reported as `.pasteEmpty`; some
  terminals use them for image-only clipboard contents, which applications can
  resolve through a host clipboard.
- Drawn cells use explicit styles. A surrounding background remains in untouched
  cells. Caller drawing work, strings, allocations, and first-use runtime metadata
  are outside the library's steady-state allocation guarantee.

## Development

```sh
swift test
swift test -c release
Scripts/check-render-allocations.sh
swift run slate-starter
swift run -c release slate-graphics-demo
swift run -c release slate-document-demo path/to/file
```

The document viewer also exercises Canvas with paging, selection, and input strips.
The macOS allocation probe checks layout growth and reuse, warmed maximum-grid
rendering, overlays, animation ticks, mouse dragging, color presentation, and
layout failure with an injected allocator counter and a positive control.
Successful frames must allocate nothing within retained capacity. Rejected layouts
allow two Swift Testing diagnostic allocations with the pinned toolchain. Output
checks use `/dev/null`; they do not measure terminal latency.
