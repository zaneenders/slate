# Slate

A Swift terminal graphics library with composable layout, Unicode cells, custom
drawing, and ANSI frame diffing. Requires Swift 6.4.2; the macOS target is 27.

Run the graphics showcase:

```sh
swift run -c release slate-graphics-demo
```

Drag the floating panel by its title bar with the left mouse button. It stays
inside the viewport and remembers its position when reopened. **O** toggles the
panel, **Escape** closes it, **Space** pauses the bars, and **Q** quits. Resize
the terminal to see the layout adapt. Animation advances at most once per 50 ms
deadline and drops missed frames instead of accumulating work.

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
- Layout uses fixed startup storage: at most 512 nodes and depth 32. Canvas shares
  the drawing table with input fields; its payload costs 16 bytes per node on
  64-bit hosts. `storageBudgetBytes` includes that table.
- Drawing runs once per nonempty canvas, in block order, after successful layout.
  Capacity rejection preserves the last frame and releases temporary references.
- Each canvas borrows the existing grid: no extra cell buffer or copying. Writes
  clip to its local area. Overwriting half an existing wide glyph also blanks its
  other half, even across the clip edge, while preserving the neighboring style.
- Drawn cells use explicit styles. A surrounding background remains in untouched
  cells. Caller drawing work, strings, allocations, and first-use runtime metadata
  are outside the library's steady-state allocation guarantee.

## Development

```sh
swift test
swift test -c release
Scripts/check-render-allocations.sh
swift run -c release slate-graphics-demo
swift run -c release slate-document-demo path/to/file
```

The document viewer also exercises Canvas with paging, selection, and input strips.
The macOS allocation probe checks warmed maximum-grid/node rendering, overlays,
mouse dragging, color presentation, and capacity rejection with an injected
allocator counter and a positive control. Successful frames must allocate
nothing. Rejected layouts allow two Swift Testing diagnostic allocations with
the pinned toolchain. Output checks use `/dev/null`; they do not measure terminal
latency.
