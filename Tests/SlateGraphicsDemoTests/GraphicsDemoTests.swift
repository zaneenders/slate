import Slate
import Testing

@testable import SlateGraphicsDemo

@Test func graphicsDemoRendersAtEmptySmallAndMaximumSizesWithoutChangingStorage() throws {
  let application = SlateGraphicsDemo()
  let configuration = SlateGraphicsDemo.configuration
  var surface = try Surface(maximumSize: configuration.maximumSize, nodeCapacity: configuration.nodeCapacity)
  let budget = surface.storageBudgetBytes
  for size in [
    TerminalSize(columns: 0, rows: 0), .init(columns: 1, rows: 1), .init(columns: 16, rows: 7),
    .init(columns: 40, rows: 16), .init(columns: 80, rows: 24), configuration.maximumSize
  ] {
    try surface.render(size: size) { application.render(in: size) }
    #expect(surface.renderedCells().count == size.columns * size.rows)
    #expect(surface.storageBudgetBytes == budget)
    for y in 0..<size.rows {
      for x in 0..<size.columns {
        let candidate = surface.cell(x: x, y: y)
        let cell = try #require(candidate)
        if cell.isContinuation {
          #expect(x > 0 && surface.cell(x: x - 1, y: y)?.glyph.columnWidth == 2)
        } else if cell.glyph.columnWidth == 2 {
          #expect(x + 1 < size.columns && surface.cell(x: x + 1, y: y)?.isContinuation == true)
        }
      }
    }
  }
  #expect(surface.cell(x: 1, y: 1)?.glyph.scalar == "S")
  #expect(surface.cell(x: 2, y: 4)?.style.background == .rgb(0, 255, 128))
}

@Test func graphicsDemoOverlayTogglesAndRestoresThePreviousComposition() throws {
  var application = SlateGraphicsDemo()
  var copy = CopyBuffer()
  let size = TerminalSize(columns: 80, rows: 24)
  var surface = try Surface(maximumSize: size, nodeCapacity: SlateGraphicsDemo.configuration.nodeCapacity)
  try surface.render(size: size) { application.render(in: size) }
  let initial = graphicsCells(surface)
  #expect(application.event(.key(.character("o")), copyBuffer: &copy) == .redraw)
  #expect(!application.showsOverlay)
  try surface.render(size: size) { application.render(in: size) }
  let uncovered = graphicsCells(surface)
  #expect(uncovered != initial)
  #expect(uncovered.contains { $0.glyph.scalar == "漢" })
  #expect(application.event(.key(.character("o")), copyBuffer: &copy) == .redraw)
  try surface.render(size: size) { application.render(in: size) }
  #expect(graphicsCells(surface) == initial)
  #expect(application.animationPhase == 0)
}

@Test func graphicsDemoAdvancesAtMostOncePerDeadlineAndHonorsPause() {
  let start = ContinuousClock().now
  var application = SlateGraphicsDemo(now: start)
  var copy = CopyBuffer()
  #expect(!application.isDue(at: start.advanced(by: .milliseconds(49))))
  #expect(application.advance(at: start.advanced(by: .milliseconds(49))) == .none)
  #expect(application.advance(at: start.advanced(by: .milliseconds(50))) == .redraw)
  #expect(application.animationPhase == 1)
  #expect(application.advance(at: start.advanced(by: .milliseconds(50))) == .none)
  let late = start.advanced(by: .seconds(3_600))
  #expect(application.advance(at: late) == .redraw)
  #expect(application.animationPhase == 2)
  #expect(!application.isDue(at: late.advanced(by: .milliseconds(49))))
  #expect(application.event(.key(.character(" ")), copyBuffer: &copy) == .redraw)
  #expect(application.isPaused && !application.isDue(at: late))
  #expect(application.advance(at: late) == .none)
  #expect(application.animationPhase == 2)
  #expect(application.event(.key(.character(" ")), copyBuffer: &copy) == .redraw)
  #expect(application.advance(at: late) == .redraw)
  #expect(application.animationPhase == 3)
  #expect(application.event(.key(.character("q")), copyBuffer: &copy) == .quit)
  #expect(application.event(.key(.character("c"), modifiers: .control), copyBuffer: &copy) == .quit)
}

private func graphicsCells(_ surface: borrowing Surface) -> [Cell] {
  (0..<(surface.size.columns * surface.size.rows)).map {
    surface.cell(x: $0 % surface.size.columns, y: $0 / surface.size.columns)!
  }
}
