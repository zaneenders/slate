import SlateUI
import Testing

@Test func customPaintingUsesTheComposedFrameAndSkipsRejectedLayouts() throws {
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 1), nodeCapacity: 2)
  var calls = 0
  try surface.render(
    size: surface.maximumSize,
    content: { Text("base") },
    paint: { frame in
      calls += 1
      #expect(frame[0, 0].glyph.scalar == "b")
      frame[0, 0] = Cell(Glyph("x")!, style: Style(foreground: .cyan))
    })
  #expect(calls == 1 && surface.cell(x: 0, y: 0)?.glyph.scalar == "x")
  #expect(surface.cell(x: 1, y: 0)?.glyph.scalar == "a")
  #expect(throws: SurfaceError.layout(.nodeCapacityExceeded)) {
    try surface.render(
      size: surface.maximumSize,
      content: { Column { Text("too many nodes") } },
      paint: { _ in calls += 1 })
  }
  #expect(throws: SurfaceError.viewportCapacityExceeded) {
    try surface.render(
      size: TerminalSize(columns: 5, rows: 1), content: { Text("oversized") },
      paint: { _ in calls += 1 })
  }
  #expect(calls == 1 && surface.cell(x: 0, y: 0)?.glyph.scalar == "x")
}
