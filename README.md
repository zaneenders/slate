# Slate

A Swift terminal graphics library with composable layout, Unicode cells, custom
drawing, and ANSI frame diffing. Requires Swift 6.4.2; the macOS target is 27.

Start with the small interactive example:

```sh
swift run starter
```

[SlateStarter.swift](Examples/SlateStarter/SlateStarter.swift) is the intended
starting point for a new application: a text input, a submitted message, and an
event handler. Type or paste into the input and press **Enter** to display the
text in the second field. Further edits update that field only after another
Enter. **Escape** or **Ctrl-C** quits; **q** is ordinary input.
Edit `render` to change the screen and `event` to change how it responds to input.
Return `.redraw` after changing state, `.none` when nothing changes, or `.quit`
to exit. Slate handles terminal setup, cleanup, and resizing.

Raw-mode keys belong to the application, including **Ctrl-Z**. Legacy Ctrl-Z
arrives as `.key(.control(.z))`; enhanced keyboard input reports
`.key(.character("z"), modifiers: .control)`, possibly with lock-state bits.
Use `modifiers.withoutLocks` when matching shortcuts.

The default executable entry point uses managed signal handling. `HUP`, `INT`,
`QUIT`, `TERM`, `ALRM`, `USR1`, `USR2`, `VTALRM`, `PROF`, `XCPU`, `XFSZ`, and
`IO` request orderly teardown; Linux also handles `PWR`. The first termination
request determines the reported signal. `TSTP`, `TTIN`, and `TTOU` are ignored
while the session owns the terminal, so job control cannot suspend restoration.
`PIPE` is ignored so failed writes can unwind normally. Resizing is polled;
`WINCH` and `CONT` need no callbacks.

The synchronous owner masks asynchronous signals on its thread during terminal
setup and teardown, then delivers pending signals while managed handlers still
own them. It restores the caller's mask and every changed disposition on exit.
Other threads can still receive signals, so handlers only latch a lock-free
atomic through a compiler-checked `@c` entry point; all cleanup runs in ordinary
Swift code. `SIGKILL` and `SIGSTOP` cannot be caught or blocked. Synchronous fault
signals keep their runtime crash handlers; child and realtime dispositions stay
with the host. Embedding applications retain their signal policy unless they
request `run(signalHandling: .managed)`.

Run the larger graphics showcase:

```sh
swift run -c release graphics
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
Padding, borders, and backgrounds preserve the child's filling axes, including
an explicit `.frame(width: .fill, height: .fill)` applied before those modifiers.

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

The runner owns scheduling. Changing the interval starts a fresh interval;
intervals must be positive. Elapsed time includes delays, and a late iteration
delivers one tick rather than catching up missed updates.
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
`.mouse` events.

## Mouse hit regions

Create a `HitMap` once and tag interactive blocks. Layout records their resolved
bounds, so hit-testing follows padding, borders, alignment, positioning, and resizing:

```swift
enum Target: Hashable { case save, panel }
private let hits = HitMap<Target>(capacity: 32)
private var capture = MouseCapture<Target>()

// Inside render:
Text("Save").padding(1).border().hitRegion(.save, in: hits)

// Inside event's .mouse case:
if let hit = hits.hitTest(mouse), mouse.action == .press, mouse.button == .left {
  switch hit.id {
  case .save: return save()
  case .panel: capture.begin(hit, in: hits)
  }
}
```

`hit.column` and `hit.row` are local to `hit.bounds`; `clippedBounds` intersects
the surface viewport. Apply `hitRegion` after padding/border to include them,
and before `position` to target the content rather than the positioner's full slot.
Hit regions add one layout node and preserve their child's sizing. For custom
blocks emitting several siblings, the modifier groups them in one overlay region,
like `background` or `border`. The group fills each axis where any child requests
`.fill`.

The frontmost registered region wins, with nested targets taking precedence over
their enclosing target. Untagged decoration passes through. Use
`.blocksMouse(in: hits)` on a panel to block targets behind its full rectangle;
nested targets inside it still work. Blocking applies within the same map.
IDs should be unique; repeated IDs use the frontmost registration for bounds and capture.

After starting a drag, call `capture.route(mouse)` before ordinary hit-testing.
It returns the captured target even outside its bounds, using its latest geometry;
local coordinates can be negative. Release returns the final position and ends
capture. A new press or movement without the captured button cancels it. Hidden
or empty targets and viewport changes also invalidate capture, even if the same
ID reappears before the next event. Keep the initial grab offset in application
state. The graphics showcase demonstrates dragging by the panel's top row.

Maps have fixed startup capacity, including blockers. Exhaustion throws
`.layout(.hitRegionCapacityExceeded)` and preserves both the previous frame and
every map's previous snapshot. Successful surface renders replace all registered
regions, clearing omitted targets and maps. One map belongs to one live surface;
sharing it throws `.layout(.hitMapInUse)`. Surface destruction releases that
ownership and clears the snapshot. Maps describe successful **surface renders**;
terminal output failure may leave a partially presented frame. For `ScreenRegion`,
convert terminal coordinates to region-local coordinates before calling
`hitTest(column:row:)`.

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

## Kitty image graphics

Use `KittyImage` and the `Output` graphics methods explicitly in a terminal that
supports the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
Raw RGB/RGBA pixels are compressed once with
[swift-zlib](https://github.com/zaneenders/swift-zlib) as an RFC 1950 zlib stream.
Prepare images before drawing, upload once, then reuse their IDs for placement:

```swift
import Slate

let output = try Output()
let pixels: [UInt8] = [255, 0, 0, 255, 0, 128, 255, 255]
let image = try KittyImage(pixels: pixels.span, width: 2, height: 1)
try output.uploadKittyImage(image, id: 1)
try output.placeKittyImage(id: 1, in: Rect(x: 2, y: 3, width: 20, height: 6))
// Reuse the image and placement ID to move or resize it without another upload.
try output.placeKittyImage(id: 1, in: Rect(x: 5, y: 4, width: 16, height: 5))
try output.deleteKittyPlacement(imageID: 1, placementID: 1) // Keep image data.
try output.deleteKittyImage(id: 1) // Release placements and image data.
```

Pixels are tightly packed in row order, without padding; `.rgba` is the default,
and `.rgb` accepts three bytes per pixel. RGBA uses straight alpha. For encoded
PNG data use `KittyImage(png: bytes.span)`; Slate checks its signature and sends
the original bytes for the terminal to decode. Uploads use direct transport in
chunks of at most 4,096 base64 bytes, so shared files are unnecessary over SSH.
Placement preserves the cursor, requests no scrolling, and fits the image inside
the requested cell rectangle. `zIndex` controls stacking; negative values draw
under text. Image and placement IDs are nonzero `UInt32` values chosen by the app.

These are terminal output primitives, with explicit lifetime and placement;
`Surface` and block layout continue to own cell graphics. Serialize image commands
with text presentation, place images after drawing cells, and restore placements
after screen clears or resizes. Re-uploading an image ID removes its previous
placements. Cleanup is explicit and destroying an image performs no terminal I/O.

In a `ScreenApplication`, implement `presentGraphics(in:to:)` to upload images
and place them after each cell frame. Implement `clearGraphics(to:)` to release
owned image IDs; Slate calls it before leaving the alternate screen on normal
exit, errors, and managed termination signals. The default executable entry
point manages signals and raw input, so Ctrl-C can return `.quit` from `event`.

Commands default to quiet replies. Pass `responses: .errors` or `.all` to upload
or placement methods to receive failures or acknowledgements. `TerminalInput`
already frames APC replies: after `.terminalReply(.applicationCommand)`, parse
`KittyGraphicsReply(input.applicationCommand)` before requesting the next event.
`ScreenApplication` delivers parsed replies as `.kittyGraphicsReply(reply)`.
The reply owns its bounded message, exposes `imageID`, `placementID`, `isSuccess`,
and `messageTruncated`, and never turns response text into key events.

For explicit capability detection call `output.queryKittyGraphics(id: queryID)`.
It sends a one-pixel query followed by a primary device attributes request, without
storing an image. A matching successful graphics reply indicates support; device
attributes arriving first indicate no support. Managed applications receive the
latter as `.primaryDeviceAttributes`. In `ScreenApplication`, configure
`.init(kittyGraphicsQueryID: queryID)` to send the query once after terminal input
is ready. Use the existing input reader, match the
query ID, and apply an application deadline if the terminal sends neither reply.
Local write success alone does not confirm terminal acceptance. Slate performs
no probing unless requested and does not inspect the environment.

Run the example in a compatible terminal. Enter, Escape, Ctrl-C, or Q exits;
resizing repositions the image without another upload:

```sh
swift run -c release kitty-graphics
```

## Bounds and costs

- Allocate drawing owners and reusable buffers before rendering. Canvas stores
  a class-bound reference, avoiding per-frame closure contexts and boxed values.
  Allocation guarantees apply to warmed, successful release-mode rendering;
  debug builds and error propagation may allocate.
- Layout uses startup-allocated `RigidArray` storage. `LayoutBudget` defaults to
  4,096 nodes (including the internal root) and 16,384 block visits per frame.
  Supported maxima are 131,072 nodes and 1,048,576 visits. `Surface`, `Screen`,
  `ScreenRegion`, and `ScreenApplicationConfiguration` accept `layoutBudget`.
  Each library-controlled block dispatch costs a visit, including custom bodies,
  builder pairs, and empty blocks. Containers are limited to 32 levels and build
  calls to 128 levels; each text/title is limited to 4,096 scalars. Node or visit
  exhaustion throws `.layout(.nodeCapacityExceeded)` or
  `.layout(.blockVisitLimitExceeded)` before painting or output, preserving the
  previous frame. Invalid budgets throw `.invalidCapacity` during initialization.
  `nodeCapacity` and `storageBudgetBytes` stay fixed. Layout element storage costs
  nodeCapacity times the sum of the node and payload strides, plus two fixed lists
  of hit-map owners. Canvas, input fields, and hit regions share the payload table.
  Each `HitMap` separately owns two fixed record buffers and an ID lookup table;
  its `storageBudgetBytes` reports that storage. Painting cost also scales with
  the cells touched across layers.
  Caller computations inside `render`, `body`, and `paint`, caller-owned strings,
  and source-collection construction remain outside the traversal/allocation bounds.
- Drawing runs once per nonempty canvas, in block order, after successful layout.
  Viewport or layout failure preserves the last frame and releases temporary references.
- Each canvas borrows the existing grid: no extra cell buffer or copying. Writes
  clip to its local area. Overwriting half an existing wide glyph also blanks its
  other half, even across the clip edge, while preserving the neighboring style.
- Focused input fields reserve the current glyph's width when scrolling and draw
  the caret independently. A one-column field uses a styled blank for a wide glyph.
- `TerminalInput` expires incomplete APC responses after 250 ms, then discards
  through their terminator for at most another 250 ms or 4,096 bytes. Recovery
  exhaustion permanently fails the input owner with `.responseRecoveryExceeded`;
  `ScreenApplication` reports `.input(.responseRecoveryExceeded)` and restores its
  terminal modes. Late response contents never become keys. `next` and `expire`
  throw typed errors; drain each batch before calling `expire`. Use `finish()`
  only for EOF; it replaces the former decoder/input `flush()` API and closes
  the owner. Suspension preserves response deadlines rather than renewing them.
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
swift run starter
swift run -c release graphics
swift run -c release kitty-graphics
swift run -c release document path/to/file
```

The document viewer also exercises Canvas with paging, selection, and input strips.
The macOS allocation probe checks fixed layout capacity and exhaustion, warmed
maximum-grid rendering, overlays, animation ticks, mouse dragging, color presentation, and
layout failure with an injected allocator counter and a positive control.
Successful frames must allocate nothing after warm-up. Rejected layouts
allow two Swift Testing diagnostic allocations with the pinned toolchain. Output
checks use `/dev/null`; they do not measure terminal latency.
