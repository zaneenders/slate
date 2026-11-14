import Slate
import SlateTestSupport
import Testing

@testable import SlateApplication
@testable import SlateNavigationDemo

@Test func navigationDemoRoutesArrowsThroughGroupsAndSeparatesEditingFromNavigation() throws {
  var application = SlateNavigationDemo()
  application.page = .sources
  var surface = try Surface(maximumSize: .init(columns: 80, rows: 24))
  var copy = CopyBuffer()
  let size = surface.maximumSize
  try surface.render(size: size) { application.render(in: size) }
  #expect(application.focus.focus(.sources))
  #expect(application.focus.focusedID == .sources)
  #expect(application.event(.key(.right), copyBuffer: &copy) == .redraw)
  #expect(application.focus.focusedID == .input)
  #expect(application.event(.key(.enter), copyBuffer: &copy) == .redraw && application.editing)
  let selected = application.focus.focusedID
  let cursor = application.input.cursorByteOffset
  #expect(application.event(.key(.left), copyBuffer: &copy) == .redraw)
  #expect(application.focus.focusedID == selected && application.input.cursorByteOffset < cursor)
  #expect(application.event(.paste("!".utf8Span), copyBuffer: &copy) == .redraw)
  #expect(application.input.snapshot() == "Edit m!e")
  #expect(application.event(.key(.escape), copyBuffer: &copy) == .redraw && !application.editing)
  #expect(application.event(.key(.right), copyBuffer: &copy) == .redraw)
  #expect(application.focus.focusedID == .output)
  #expect(application.event(.paste("ignored".utf8Span), copyBuffer: &copy) == .none)
  #expect(application.event(.key(.control(.q)), copyBuffer: &copy) == .quit)
}

@Test func navigationDemoReflowsAndUsesTheSameBoundsForMouseFocus() throws {
  var application = SlateNavigationDemo()
  application.page = .sources
  var surface = try Surface(maximumSize: .init(columns: 100, rows: 40))
  var copy = CopyBuffer()
  for size in [surface.maximumSize, TerminalSize(columns: 44, rows: 36)] {
    try surface.render(size: size) { application.render(in: size) }
    let bounds = try #require(application.focus.bounds(for: .run))
    _ = application.focus.focus(.sources)
    #expect(
      application.event(
        .mouse(.init(action: .press, button: .left, column: bounds.x, row: bounds.y)), copyBuffer: &copy) == .redraw)
    #expect(application.focus.focusedID == .run)
  }
  #expect(application.event(.key(.enter), copyBuffer: &copy) == .redraw)
  #expect(application.lastAction == "Activated Run")
}

@Test func navigationDemoSidebarOpensDistinctPagesAndKeepsTheActivePageMarked() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 80, rows: 24)
  var screen = try Screen(maximumSize: size)
  var application = SlateNavigationDemo()
  var copy = CopyBuffer()
  try present(&application, on: &screen, size: size, to: output)
  let pages: [(NavigationTarget, NavigationPage, NavigationTarget)] = [
    (.tests, .tests, .layoutSuite), (.docs, .docs, .article),
    (.tools, .tools, .scratchpad), (.sources, .sources, .input),
    (.overview, .overview, .signal), (.gallery, .gallery, .artwork)
  ]
  for (sidebar, page, control) in pages {
    #expect(application.focus.focus(sidebar))
    #expect(application.page != page)
    #expect(application.event(.key(.enter), copyBuffer: &copy) == .redraw)
    try present(&application, on: &screen, size: size, to: output)
    #expect(application.page == page && application.focus.focusedID == sidebar)
    for (_, expectedPage, target) in pages {
      #expect((application.focus.bounds(for: target) != nil) == (page == expectedPage))
    }
    #expect(application.focus.focus(control))
    try present(&application, on: &screen, size: size, to: output)
    let bounds = try #require(application.focus.bounds(for: sidebar))
    #expect(screen.cell(x: bounds.x + 1, y: bounds.y)?.style.underlined == true)
    #expect(screen.cell(x: bounds.x + 1, y: bounds.y)?.style.foreground == application.accent)
  }
}

@Test func navigationDemoMouseOpensPagesAndAllPagesReflow() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let maximum = TerminalSize(columns: 100, rows: 40)
  var screen = try Screen(maximumSize: maximum)
  var application = SlateNavigationDemo()
  var copy = CopyBuffer()
  let pages: [(NavigationTarget, NavigationPage, NavigationTarget)] = [
    (.tests, .tests, .clearSuites), (.docs, .docs, .article),
    (.tools, .tools, .resetTools), (.sources, .sources, .run),
    (.overview, .overview, .signal), (.gallery, .gallery, .artwork)
  ]
  for size in [maximum, TerminalSize(columns: 44, rows: 36)] {
    try present(&application, on: &screen, size: size, to: output)
    for (sidebar, page, control) in pages {
      #expect(application.focus.focus(sidebar))
      // Clicking empty space must not activate the currently focused sidebar item.
      #expect(
        application.event(.mouse(.init(action: .press, button: .left, column: 0, row: 0)), copyBuffer: &copy) == .none)
      #expect(application.page != page)
      let bounds = try #require(application.focus.bounds(for: sidebar))
      #expect(
        application.event(
          .mouse(.init(action: .press, button: .left, column: bounds.x, row: bounds.y)), copyBuffer: &copy) == .redraw)
      try present(&application, on: &screen, size: size, to: output)
      #expect(application.page == page && application.focus.focusedID == sidebar)
      let content = try #require(application.focus.bounds(for: control))
      #expect(size.columns >= 54 ? content.x > bounds.x : content.y > bounds.y)
      #expect(
        application.event(
          .mouse(.init(action: .press, button: .left, column: content.x, row: content.y)), copyBuffer: &copy) == .redraw
      )
      #expect(application.focus.focusedID == control)
    }
  }
}

@Test func navigationDemoPreservesPageStateAndRoutesEditingToTheVisibleInput() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 80, rows: 24)
  var screen = try Screen(maximumSize: size)
  var application = SlateNavigationDemo()
  application.page = .sources
  var copy = CopyBuffer()
  try present(&application, on: &screen, size: size, to: output)
  #expect(application.focus.focus(.input))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  _ = application.event(.paste("!".utf8Span), copyBuffer: &copy)
  _ = application.event(.key(.escape), copyBuffer: &copy)
  try open(.tests, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(application.focus.focus(.unicodeSuite))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.unicodeSuite)
  try open(.docs, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(application.focus.focus(.inputGuide))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  try present(&application, on: &screen, size: size, to: output)
  #expect(snapshot(screen, size: size).contains("Enter starts editing an input field."))
  try open(.tools, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(application.focus.focus(.scratchpad))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.editing)
  _ = application.event(.paste("!".utf8Span), copyBuffer: &copy)
  _ = application.event(.key(.escape), copyBuffer: &copy)
  #expect(application.focus.focus(.greenAccent))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.accent == .green)
  try open(.sources, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(application.input.snapshot() == "Edit me!")
  try open(.tests, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(application.unicodeSuite)
  #expect(application.focus.focus(.clearSuites))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(!application.layoutSuite && !application.inputSuite && !application.unicodeSuite)
  #expect(application.focus.focus(.selectAllSuites))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.layoutSuite && application.inputSuite && application.unicodeSuite)
  try open(.docs, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(snapshot(screen, size: size).contains("Enter starts editing an input field."))
  try open(.tools, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(application.scratchpad.snapshot() == "A note that stays here!")
  #expect(application.accent == .green)
  #expect(application.focus.focus(.resetTools))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.accent == .cyan && application.scratchpad.snapshot() == "A note that stays here")
  #expect(application.input.snapshot() == "Edit me!")
}

@Test func navigationDemoDefersArrowsInAPageSwitchBatchUntilTheNewLayoutCommits() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 80, rows: 24)
  var runner = try ScreenRunner(configuration: SlateNavigationDemo.configuration)
  var application = SlateNavigationDemo()
  #expect(try runner.draw(application: &application, actualSize: size, to: output))
  #expect(try runner.receive("\u{1b}[B\u{1b}[B\r\u{1b}[C".utf8Span.span, at: .now, application: &application))
  #expect(application.page == .tests && application.focus.focusedID == .tests)
  #expect(!application.hasPendingWork)
  let continuedBeforeLayout = runner.performPendingWork(application: &application)
  #expect(continuedBeforeLayout)
  #expect(application.focus.focusedID == .tests)
  #expect(try runner.draw(application: &application, actualSize: size, to: output))
  #expect(application.hasPendingWork)
  let continuedAfterLayout = runner.performPendingWork(application: &application)
  #expect(continuedAfterLayout)
  #expect(!application.hasPendingWork)
  #expect(application.focus.focusedID?.page == nil)
  #expect(application.focus.bounds(for: .input) == nil)
  #expect(application.focus.bounds(for: .layoutSuite) != nil)
  #expect(try runner.draw(application: &application, actualSize: size, to: output))
}

@Test func navigationDemoAnimatesOnlyWhenNeededAndRunsSelectedSampleSuites() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 80, rows: 24)
  var screen = try Screen(maximumSize: size)
  var application = SlateNavigationDemo()
  var copy = CopyBuffer()
  try present(&application, on: &screen, size: size, to: output)
  #expect(application.tickInterval == .milliseconds(100))
  let phase = application.signal.phase
  #expect(application.event(.tick(elapsed: .milliseconds(100)), copyBuffer: &copy) == .redraw)
  #expect(application.signal.phase != phase)
  #expect(application.focus.focus(.barsMetric))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.signal.mode == .bars)
  #expect(application.focus.focus(.heatMetric))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.signal.mode == .heatmap)
  _ = application.event(.key(.character(" ")), copyBuffer: &copy)
  #expect(application.tickInterval == nil)
  #expect(application.event(.tick(elapsed: .milliseconds(100)), copyBuffer: &copy) == .none)
  try open(.tests, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(application.focus.focus(.runSuites))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.runningTests && application.testCount == 149)
  #expect(application.tickInterval != nil)
  // The run snapshots the selected suites and continues across page changes.
  try open(.docs, in: &application, on: &screen, size: size, to: output, copy: &copy)
  for _ in 0..<20 { _ = application.event(.tick(elapsed: .milliseconds(100)), copyBuffer: &copy) }
  #expect(application.testProgress == 100 && !application.runningTests)
  #expect(application.lastAction.contains("149 checks passed") && application.tickInterval == nil)
  try open(.tests, in: &application, on: &screen, size: size, to: output, copy: &copy)
  #expect(snapshot(screen, size: size).contains("All selected checks passed"))
  #expect(application.focus.focus(.clearSuites))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.focus.focus(.runSuites))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(!application.runningTests && application.lastAction.contains("at least one suite"))
}

@Test func navigationDemoChangesPreviewsColorsAndThemesAndClipsSmallViewports() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let maximum = TerminalSize(columns: 100, rows: 40)
  var screen = try Screen(maximumSize: maximum)
  var application = SlateNavigationDemo()
  var copy = CopyBuffer()
  try present(&application, on: &screen, size: maximum, to: output)
  try open(.sources, in: &application, on: &screen, size: maximum, to: output, copy: &copy)
  #expect(application.focus.focus(.drawing))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  try present(&application, on: &screen, size: maximum, to: output)
  #expect(snapshot(screen, size: maximum).contains("func paint(in frame: inout Frame)"))
  try open(.tools, in: &application, on: &screen, size: maximum, to: output, copy: &copy)
  #expect(application.focus.focus(.coralAccent))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  #expect(application.accent == StudioPalette.coral)
  #expect(application.focus.focus(.toggleTheme))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  try present(&application, on: &screen, size: maximum, to: output)
  #expect(application.lightTheme && screen.cell(x: 0, y: 0)?.style.background == application.palette.background)
  // Every page also renders safely when most of it is clipped away.
  for page in [NavigationPage.overview, .sources, .tests, .docs, .tools, .gallery] {
    application.page = page
    for size in [TerminalSize(columns: 54, rows: 24), .init(columns: 26, rows: 16), .init(columns: 1, rows: 1)] {
      try present(&application, on: &screen, size: size, to: output)
      if let selected = application.focus.focusedID {
        let bounds = try #require(application.focus.bounds(for: selected))
        #expect(bounds.right <= size.columns && bounds.bottom <= size.rows)
      }
    }
  }
}

@Test func navigationDemoLeftFromSuiteRowsGoesDirectlyToTheSidebar() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: .init(columns: 240, rows: 80))
  var application = SlateNavigationDemo()
  var copy = CopyBuffer()
  let initialSize = TerminalSize(columns: 80, rows: 24)
  try present(&application, on: &screen, size: initialSize, to: output)
  try open(.tests, in: &application, on: &screen, size: initialSize, to: output, copy: &copy)
  for size in [initialSize, .init(columns: 132, rows: 48), .init(columns: 240, rows: 80)] {
    try present(&application, on: &screen, size: size, to: output)
    for suite in [NavigationTarget.layoutSuite, .inputSuite, .unicodeSuite] {
      #expect(application.focus.focus(suite))
      #expect(application.event(.key(.left), copyBuffer: &copy) == .redraw)
      #expect(application.focus.focusedID?.page != nil)
      #expect(application.page == .tests)
    }
  }
}

@Test func navigationDemoSidebarEdgesFollowThePanelsAfterReflow() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: .init(columns: 240, rows: 80))
  var application = SlateNavigationDemo()
  var copy = CopyBuffer()
  let initialSize = TerminalSize(columns: 80, rows: 24)
  try present(&application, on: &screen, size: initialSize, to: output)
  // Gallery remains the last sidebar item even while the Tests page is open.
  try open(.tests, in: &application, on: &screen, size: initialSize, to: output, copy: &copy)
  for size in [initialSize, .init(columns: 132, rows: 48), .init(columns: 240, rows: 80)] {
    try present(&application, on: &screen, size: size, to: output)
    #expect(application.focus.focus(.gallery))
    for _ in 0..<3 {
      _ = application.event(.key(.down), copyBuffer: &copy)
      #expect(application.focus.focusedID == .gallery && application.page == .tests)
    }
    _ = application.event(.key(.right), copyBuffer: &copy)
    #expect(application.focus.focusedID?.page == nil)
    #expect(application.focus.focusedID != nil)
    #expect(application.focus.focus(.overview))
    _ = application.event(.key(.up), copyBuffer: &copy)
    #expect(application.focus.focusedID == .overview)
  }
  let narrow = TerminalSize(columns: 44, rows: 36)
  try present(&application, on: &screen, size: narrow, to: output)
  #expect(application.focus.focus(.gallery))
  _ = application.event(.key(.down), copyBuffer: &copy)
  #expect(application.focus.focusedID?.page == nil && application.focus.focusedID != nil)
  let bounds = try #require(application.focus.bounds(for: application.focus.focusedID!))
  let gallery = try #require(application.focus.bounds(for: .gallery))
  #expect(bounds.y > gallery.bottom)
}

@Test func navigationDemoKittyProbeUsesTheExistingReaderAndFallsBackOnUnsupportedTerminals() throws {
  var application = SlateNavigationDemo()
  var runner = try ScreenRunner(configuration: SlateNavigationDemo.configuration)
  #expect(try runner.receive("\u{1b}_Gi=4198;OK\u{1b}\\".utf8Span.span, at: .now, application: &application))
  #expect(application.graphicsSupport == .probing)
  #expect(
    try runner.receive("\u{1b}_Gi=4199;OK\u{1b}\\\u{1b}[?1;2c".utf8Span.span, at: .now, application: &application))
  #expect(application.graphicsSupport == .supported)
  #expect(
    try runner.receive("\u{1b}_Gi=4200;EINVAL:unsupported\u{1b}\\".utf8Span.span, at: .now, application: &application))
  #expect(application.graphicsSupport == .unavailable)
  var fallback = SlateNavigationDemo()
  var copy = CopyBuffer()
  _ = fallback.event(.primaryDeviceAttributes, copyBuffer: &copy)
  #expect(fallback.graphicsSupport == .unavailable)
  #expect(fallback.galleryStatus.contains("unavailable"))
}

@Test func navigationDemoKittyImagesReuseUploadsFollowLayoutAndCleanUpOnPageChanges() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 80, rows: 24)
  var screen = try Screen(maximumSize: .init(columns: 100, rows: 40))
  var application = SlateNavigationDemo()
  var copy = CopyBuffer()
  try present(&application, on: &screen, size: size, to: output)
  try open(.gallery, in: &application, on: &screen, size: size, to: output, copy: &copy)
  _ = try capture.take()
  try application.presentGraphics(in: size, to: output)
  #expect(try capture.take().isEmpty && application.images == nil)
  let bounds = try #require(application.focus.bounds(for: .artwork))
  #expect(screen.cell(x: bounds.x, y: bounds.y)?.glyph.scalar == "▀")
  application.graphicsSupport = .supported
  try present(&application, on: &screen, size: size, to: output)
  _ = try capture.take()
  try application.presentGraphics(in: size, to: output)
  let first = String(decoding: try capture.take(), as: UTF8.self)
  #expect(first.contains("a=t,t=d,f=24,s=256,v=160,o=z,i=4200"))
  #expect(first.contains("a=p,i=4200,p=1,c=\(bounds.width),r=\(bounds.height)"))
  try application.presentGraphics(in: size, to: output)
  let repeatFrame = String(decoding: try capture.take(), as: UTF8.self)
  #expect(!repeatFrame.contains("a=t,") && repeatFrame.contains("a=p,i=4200"))
  #expect(application.focus.focus(.orbit))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  try present(&application, on: &screen, size: size, to: output)
  _ = try capture.take()
  try application.presentGraphics(in: size, to: output)
  let changed = String(decoding: try capture.take(), as: UTF8.self)
  #expect(changed.contains("a=d,d=i,i=4200,p=1") && changed.contains("a=p,i=4201"))
  let narrow = TerminalSize(columns: 44, rows: 36)
  try present(&application, on: &screen, size: narrow, to: output)
  _ = try capture.take()
  let reflow = try #require(application.focus.bounds(for: .artwork))
  try application.presentGraphics(in: narrow, to: output)
  let resized = String(decoding: try capture.take(), as: UTF8.self)
  #expect(resized.contains("a=p,i=4201,p=1,c=\(reflow.width),r=\(reflow.height)"))
  #expect(!resized.contains("a=t,"))
  #expect(application.focus.focus(.toggleKitty))
  _ = application.event(.key(.enter), copyBuffer: &copy)
  try present(&application, on: &screen, size: narrow, to: output)
  _ = try capture.take()
  try application.presentGraphics(in: narrow, to: output)
  #expect(String(decoding: try capture.take(), as: UTF8.self).contains("a=d,d=i,i=4201,p=1"))
  #expect(application.placedImageID == nil)
  #expect(screen.cell(x: reflow.x, y: reflow.y)?.glyph.scalar == "▀")
  _ = application.event(.key(.enter), copyBuffer: &copy)
  try present(&application, on: &screen, size: narrow, to: output)
  try application.presentGraphics(in: narrow, to: output)
  try open(.docs, in: &application, on: &screen, size: narrow, to: output, copy: &copy)
  _ = try capture.take()
  try application.presentGraphics(in: narrow, to: output)
  #expect(String(decoding: try capture.take(), as: UTF8.self).contains("a=d,d=i,i=4201,p=1"))
  try application.clearGraphics(to: output)
  let cleanup = String(decoding: try capture.take(), as: UTF8.self)
  #expect(cleanup.contains("a=d,d=I,i=4200") && cleanup.contains("a=d,d=I,i=4201"))
  #expect(application.uploadedImages == 0)
  try application.clearGraphics(to: output)
  #expect(try capture.take().isEmpty)
}

private func present(
  _ application: inout SlateNavigationDemo, on screen: inout Screen, size: TerminalSize, to output: borrowing Output
) throws {
  let statistics = try screen.draw(size: size, to: output) { application.render(in: size) }
  application.didPresentFrame(statistics)
}

private func open(
  _ page: NavigationTarget, in application: inout SlateNavigationDemo, on screen: inout Screen,
  size: TerminalSize, to output: borrowing Output, copy: inout CopyBuffer
) throws {
  #expect(application.focus.focus(page))
  #expect(application.event(.key(.enter), copyBuffer: &copy) == .redraw)
  try present(&application, on: &screen, size: size, to: output)
  #expect(application.page == page.page)
}

private func snapshot(_ screen: borrowing Screen, size: TerminalSize) -> String {
  var result = ""
  for row in 0..<size.rows {
    for column in 0..<size.columns {
      result.unicodeScalars.append(screen.cell(x: column, y: row)!.glyph.scalar)
    }
    result += "\n"
  }
  return result
}
