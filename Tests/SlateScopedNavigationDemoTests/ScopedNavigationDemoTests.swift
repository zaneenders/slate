import Slate
import Testing

@testable import SlateScopedNavigationDemo

@Test(arguments: [TerminalSize(columns: 100, rows: 24), .init(columns: 40, rows: 16)])
func scopedDemoKeepsMovementLocalAndRevealsCollapsedPanes(size: TerminalSize) throws {
  var app = SlateScopedNavigationDemo()
  var surface = try Surface(maximumSize: size, layoutBudget: .init())
  var copy = CopyBuffer()
  try surface.render(size: size) { app.render(in: size) }
  for _ in 0..<8 { _ = app.event(.key(.character("j"), modifiers: []), copyBuffer: &copy) }
  #expect(app.workspace.selected == 2 && app.focus.focusedID == .notes)
  _ = app.event(.key(.control(.l), modifiers: []), copyBuffer: &copy)
  #expect(app.focus.focusedID == .reader)
  try surface.render(size: size) { app.render(in: size) }
  #expect(app.focus.bounds(for: .reader) != nil)
  _ = app.event(.key(.character("j"), modifiers: []), copyBuffer: &copy)
  #expect(app.workspace.scrollLine == 1 && app.workspace.selected == 2)
  _ = app.event(.key(.control(.h), modifiers: []), copyBuffer: &copy)
  #expect(app.focus.focusedID == .notes && app.workspace.scrollLine == 1)
  try surface.render(size: size) { app.render(in: size) }
  #expect(app.focus.bounds(for: .notes) != nil)
  _ = app.event(.key(.control(.w), modifiers: []), copyBuffer: &copy)
  _ = app.event(.key(.character("l"), modifiers: []), copyBuffer: &copy)
  #expect(app.focus.focusedID == .reader)
}

@Test func scopedDemoDialogOwnsInputAndRestoresTheReader() throws {
  var app = SlateScopedNavigationDemo()
  let size = TerminalSize(columns: 100, rows: 24)
  var surface = try Surface(maximumSize: size, layoutBudget: .init())
  var copy = CopyBuffer()
  try surface.render(size: size) { app.render(in: size) }
  _ = app.event(.key(.enter, modifiers: []), copyBuffer: &copy)
  _ = app.event(.key(.character("j"), modifiers: []), copyBuffer: &copy)
  _ = app.event(.key(.character("?"), modifiers: []), copyBuffer: &copy)
  try surface.render(size: size) { app.render(in: size) }
  #expect(app.navigation.activeScope == .help)
  for _ in 0..<8 {
    _ = app.event(.key(.character("j"), modifiers: []), copyBuffer: &copy)
    _ = app.event(.key(.control(.h), modifiers: []), copyBuffer: &copy)
  }
  #expect(app.help.selected == 2 && app.workspace.scrollLine == 1 && app.workspace.selected == 0)
  #expect(app.navigation.activeScope == .help)
  #expect(app.event(.key(.character("q"), modifiers: []), copyBuffer: &copy) == .none)
  let behind = try #require(app.focus.bounds(for: .notes))
  _ = app.event(
    .mouse(.init(action: .press, button: .left, column: behind.x, row: behind.y, modifiers: [])),
    copyBuffer: &copy)
  #expect(app.navigation.activeScope == .help && app.focus.focusedID == .reader)
  _ = app.event(.key(.escape, modifiers: []), copyBuffer: &copy)
  #expect(app.navigation.activeScope == .workspace && app.focus.focusedID == .reader)
  _ = app.event(.key(.escape, modifiers: []), copyBuffer: &copy)
  #expect(app.focus.focusedID == .notes)
  _ = app.event(.key(.escape, modifiers: []), copyBuffer: &copy)
  #expect(app.focus.focusedID == .notes)
}

@Test func scopedDemoPreservesStateAcrossTinyAndSplitViewports() throws {
  var app = SlateScopedNavigationDemo()
  var surface = try Surface(maximumSize: .init(columns: 100, rows: 30), layoutBudget: .init())
  var copy = CopyBuffer()
  let wide = TerminalSize(columns: 100, rows: 24)
  try surface.render(size: wide) { app.render(in: wide) }
  _ = app.event(.key(.character("j"), modifiers: []), copyBuffer: &copy)
  _ = app.event(.key(.control(.l), modifiers: []), copyBuffer: &copy)
  _ = app.event(.key(.character("j"), modifiers: []), copyBuffer: &copy)
  for size in [TerminalSize(columns: 1, rows: 1), .init(columns: 40, rows: 16), wide] {
    try surface.render(size: size) { app.render(in: size) }
    #expect(surface.size == size)
    #expect(app.workspace.selected == 1 && app.workspace.scrollLine == 1)
  }
  _ = app.event(.key(.character("?"), modifiers: []), copyBuffer: &copy)
  for size in [TerminalSize(columns: 1, rows: 1), .init(columns: 40, rows: 16), wide] {
    try surface.render(size: size) { app.render(in: size) }
    #expect(app.navigation.activeScope == .help)
  }
}
