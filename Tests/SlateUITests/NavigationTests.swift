import SlateUI
import Testing

private enum TestScope: Hashable { case workspace, dialog, nested }
private enum TestTarget: Hashable { case list, reader, field, button }

@Test func navigationKeepsContentMovementLocalAndUsesCtrlForFocus() throws {
  let focus = FocusState<TestTarget>(capacity: 4, initial: .list)
  let router = NavigationRouter(root: TestScope.workspace, focus: focus, capacity: 3)
  var surface = try Surface(maximumSize: .init(columns: 40, rows: 8), layoutBudget: .init())
  try surface.render(size: surface.maximumSize) {
    Row(gap: 1) {
      Text("list").focusTarget(.list, in: focus, enabled: true)
      Text("reader").focusTarget(.reader, in: focus, enabled: true)
    }
  }
  switch router.route(.character("j"), modifiers: [], mode: .normal) {
  case .routed(.action(.workspace, .list, .move(.down))): break
  default: Issue.record("Content movement must be delivered only to the focused list")
  }
  #expect(focus.focusedID == .list)
  for key in [InputKey.control(.l), .character("l")] {
    _ = router.focus(.list)
    let modifiers: KeyModifiers = key == .character("l") ? [.control, .capsLock] : []
    switch router.route(key, modifiers: modifiers, mode: .normal) {
    case .routed(.focusChanged(.workspace, .reader)): break
    default: Issue.record("Both keyboard encodings must move region focus")
    }
    #expect(focus.focusedID == .reader)
    switch router.route(.focus(.right)) {
    case .blocked(.workspace): break
    default: Issue.record("A region boundary must consume navigation without wrapping")
    }
  }
}

@Test func navigationInsertKeepsEditingKeysAndDoesNotUseTabOrPage() {
  var keys = NavigationKeymap()
  for key in [InputKey.character("h"), .character("j"), .character("k"), .character("l"), .control(.h), .control(.w)] {
    #expect(keys.resolve(key, modifiers: [], mode: .insert) == .unhandled)
  }
  #expect(keys.resolve(.escape, modifiers: [], mode: .insert) == .intent(.back))
  for mode in [NavigationMode.normal, .insert] {
    for key in [InputKey.tab, .pageUp, .pageDown] {
      #expect(keys.resolve(key, modifiers: [], mode: mode) == .unhandled)
    }
  }
  #expect(keys.resolve(.character("j"), modifiers: .alt, mode: .normal) == .unhandled)
  #expect(keys.resolve(.character("j"), modifiers: .shift, mode: .normal) == .unhandled)
  #expect(keys.resolve(.enter, modifiers: .control, mode: .normal) == .unhandled)
}

@Test func navigationWindowPrefixCancelsAndProducesTheSameFocusIntents() {
  var keys = NavigationKeymap()
  for (key, direction) in [
    (InputKey.character("h"), FocusDirection.left), (.character("j"), .down),
    (.character("k"), .up), (.character("l"), .right), (.backspace, .left)
  ] {
    #expect(keys.resolve(.character("w"), modifiers: .control, mode: .normal) == .consumed)
    #expect(keys.windowPending)
    #expect(keys.resolve(key, modifiers: [], mode: .normal) == .intent(.focus(direction)))
    #expect(!keys.windowPending)
  }
  _ = keys.resolve(.control(.w), modifiers: [], mode: .normal)
  #expect(keys.resolve(.escape, modifiers: [], mode: .normal) == .consumed)
  #expect(keys.resolve(.character("j"), modifiers: [], mode: .normal) == .intent(.move(.down)))
  _ = keys.resolve(.control(.w), modifiers: [], mode: .normal)
  #expect(keys.resolve(.character("j"), modifiers: [], mode: .insert) == .unhandled)
  #expect(!keys.windowPending)
}

@Test func navigationScopesBlockUnderlyingTargetsAndRestoreNestedFocus() throws {
  let root = FocusState<TestTarget>(capacity: 2, initial: .reader)
  let dialog = FocusState<TestTarget>(capacity: 2, initial: .field)
  let nested = FocusState<TestTarget>(capacity: 1, initial: .button)
  let router = NavigationRouter(root: TestScope.workspace, focus: root, capacity: 3)
  var surface = try Surface(maximumSize: .init(columns: 40, rows: 8), layoutBudget: .init())
  try surface.render(size: surface.maximumSize) {
    Column(gap: 1) {
      Row {
        Text("list").focusTarget(.list, in: root, enabled: true)
        Text("reader").focusTarget(.reader, in: root, enabled: true)
      }
      Row {
        Text("field").focusTarget(.field, in: dialog, enabled: true)
        Text("button").focusTarget(.button, in: dialog, enabled: true)
      }
      Text("nested").focusTarget(.button, in: nested, enabled: true)
    }
  }
  #expect(router.push(.dialog, focus: dialog))
  #expect(!router.focus(.list))
  let behind = try #require(root.bounds(for: .list))
  #expect(!router.focus(column: behind.x, row: behind.y))
  #expect(router.focusedID == .field && root.focusedID == .reader)
  for mode in [NavigationMode.normal, .insert] {
    switch router.route(.character("x"), modifiers: [], mode: mode) {
    case .input(.dialog, .field): break
    default: Issue.record("Raw keys must retain their dialog owner, including while typing")
    }
  }
  switch router.route(.activate) {
  case .action(.dialog, .field, .activate): break
  default: Issue.record("Activation must be scoped to the dialog")
  }
  _ = router.route(.focus(.right))
  #expect(router.focusedID == .button)
  #expect(router.push(.nested, focus: nested))
  #expect(!router.push(.workspace, focus: root))
  #expect(router.count == 3)
  #expect(router.pop() && router.activeScope == .dialog && router.focusedID == .button)
  #expect(router.pop() && router.activeScope == .workspace && router.focusedID == .reader)
  #expect(!router.pop())
}

@Test func navigationScopeAdmissionAndPrefixStateAreAtomicAtCapacity() {
  let root = FocusState<Int>(capacity: 1, initial: nil)
  let dialog = FocusState<Int>(capacity: 1, initial: nil)
  let nested = FocusState<Int>(capacity: 1, initial: nil)
  let router = NavigationRouter(root: 0, focus: root, capacity: 2)
  #expect(!router.push(0, focus: dialog))
  #expect(!router.push(1, focus: root))
  _ = router.route(.control(.w), modifiers: [], mode: .normal)
  #expect(router.push(1, focus: dialog))
  #expect(!router.windowPending)
  _ = router.route(.control(.w), modifiers: [], mode: .normal)
  #expect(!router.push(2, focus: nested))
  #expect(router.windowPending && router.activeScope == 1)
  switch router.route(.back) {
  case .action(1, nil, .back): break
  default: Issue.record("An empty dialog must still receive Back")
  }
  #expect(router.pop() && !router.windowPending)
  switch router.route(.activate) {
  case .blocked(0): break
  default: Issue.record("An empty scope cannot activate an unregistered target")
  }
}

@Test func navigationRestoresAfterHiddenParentLayoutAndFallsBackForRemovedTargets() throws {
  let root = FocusState<TestTarget>(capacity: 2, initial: .reader)
  let dialog = FocusState<TestTarget>(capacity: 1, initial: .field)
  let router = NavigationRouter(root: TestScope.workspace, focus: root, capacity: 2)
  var surface = try Surface(maximumSize: .init(columns: 20, rows: 4), layoutBudget: .init())
  try surface.render(size: surface.maximumSize) {
    Text("reader").focusTarget(.reader, in: root, enabled: true)
  }
  #expect(router.push(.dialog, focus: dialog))
  try surface.render(size: surface.maximumSize) {
    Text("field").focusTarget(.field, in: dialog, enabled: true)
  }
  #expect(root.focusedID == nil && router.pop())
  #expect(root.focusedID == .reader && root.bounds(for: .reader) == nil)
  try surface.render(size: surface.maximumSize) { Text("loading").navigationGroup(in: root) }
  #expect(root.focusedID == .reader && !root.contains(.reader))
  var paintedTarget: TestTarget?
  try surface.render(
    size: surface.maximumSize,
    content: {
      if root.isFocused(.reader) {
        Text("reader").focusTarget(.reader, in: root, enabled: true)
      } else {
        Text("list").focusTarget(.list, in: root, enabled: true)
      }
    }, paint: { _ in paintedTarget = root.focusedID })
  #expect(paintedTarget == .reader)
  #expect(root.focusedID == .reader)
  #expect(router.push(.dialog, focus: dialog))
  try surface.render(size: surface.maximumSize) {
    Text("field").focusTarget(.field, in: dialog, enabled: true)
  }
  #expect(router.pop())
  try surface.render(
    size: surface.maximumSize,
    content: { Text("replacement").focusTarget(.list, in: root, enabled: true) },
    paint: { _ in paintedTarget = root.focusedID })
  #expect(paintedTarget == .list)
  #expect(root.focusedID == .list)
  root.requestFocus(.list)
  try surface.render(
    size: surface.maximumSize,
    content: { Text("reader").focusTarget(.reader, in: root, enabled: true) },
    paint: { _ in paintedTarget = root.focusedID })
  #expect(paintedTarget == .reader && root.focusedID == .reader)
}

@Test func navigationCollapsedRegionsRemainReachableWithoutMouseOrAutomaticFocus() throws {
  let focus = FocusState<TestTarget>(capacity: 3, initial: .list)
  var surface = try Surface(maximumSize: .init(columns: 20, rows: 4), layoutBudget: .init())
  try surface.render(size: surface.maximumSize) {
    Text("list").navigationRegion(
      .list, in: focus, enabled: true, visibility: .visible,
      neighbors: .init(left: nil, right: .reader, up: nil, down: .field))
    Text("").frame(width: .fixed(0), height: .fixed(0)).navigationRegion(
      .reader, in: focus, enabled: true, visibility: .collapsed,
      neighbors: .init(left: .list, right: nil, up: nil, down: nil))
    Text("disabled").navigationRegion(
      .field, in: focus, enabled: false, visibility: .visible, neighbors: .automatic)
  }
  #expect(focus.contains(.reader) && focus.bounds(for: .reader) == nil)
  #expect(!focus.move(.down) && focus.focusedID == .list)
  #expect(focus.move(.right) && focus.focusedID == .reader)
  #expect(!focus.move(.down))
  #expect(focus.move(.left) && focus.focusedID == .list)

  _ = focus.clear()
  try surface.render(size: surface.maximumSize) {
    Text("").frame(width: .fixed(0), height: .fixed(0)).navigationRegion(
      .reader, in: focus, enabled: true, visibility: .collapsed, neighbors: .automatic)
    Text("list").focusTarget(.list, in: focus, enabled: true)
  }
  #expect(focus.move(.right) && focus.focusedID == .list)
}
