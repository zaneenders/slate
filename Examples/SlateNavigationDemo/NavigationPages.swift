import Slate

extension SlateNavigationDemo {
  func sidebar(compact: Bool) -> some Block {
    Column(gap: compact ? 0 : 1) {
      target(.overview)
      target(.sources)
      target(.tests)
      target(.docs)
      target(.tools)
      target(.gallery)
    }.padding(1).border("WORKSPACE", style: borderStyle())
      .background(palette.panel).navigationGroup(in: focus)
  }

  var pageContent: some Block { pageBody.navigationGroup(in: focus) }

  @BlockBuilder var pageBody: some Block {
    switch page {
    case .overview: overviewPage
    case .sources: sourcesPage
    case .tests: testsPage
    case .docs: docsPage
    case .tools: toolsPage
    case .gallery: galleryPage
    }
  }

  var overviewPage: some Block {
    Column(gap: 1) {
      Row(gap: 1) {
        metric(.waveMetric, title: "SIGNAL", value: "Wave", detail: "flow", color: StudioPalette.mint)
        metric(.barsMetric, title: "ACTIVITY", value: "Bars", detail: "pulse", color: StudioPalette.sky)
        metric(.heatMetric, title: "DENSITY", value: "Heat", detail: "field", color: StudioPalette.lilac)
      }.navigationGroup(in: focus)
      Canvas(signal).border(
        animating ? "LIVE / sample signals" : "PAUSED / sample signals", style: borderStyle(.signal)
      )
      .background(palette.panel).frame(width: .fill, height: .fill).focusTarget(.signal, in: focus)
      Row(gap: 1) {
        target(.pauseAnimation)
        target(.shuffleSignal)
        target(.exploreGallery)
      }.padding(horizontal: 1).border("PLAYGROUND / Space pauses", style: borderStyle())
        .background(palette.panel).navigationGroup(in: focus)
    }
  }

  func metric(_ id: NavigationTarget, title: String, value: String, detail: String, color: Color) -> some Block {
    Column {
      Text(value, style: Style(foreground: color, background: palette.panel, bold: true))
      Text(detail, style: Style(foreground: palette.muted, background: palette.panel))
    }.padding(horizontal: 1).border(title, style: borderStyle(id, tint: color))
      .background(palette.panel).frame(width: .fill).focusTarget(id, in: focus)
  }

  var sourcesPage: some Block {
    Column(gap: 1) {
      Column(gap: 1) {
        Row(gap: 1) {
          target(.layout)
          target(.drawing)
        }
        Row(gap: 1) {
          InputBox(input, focused: editing && focus.isFocused(.input), style: targetStyle(.input))
            .padding(horizontal: 1).background(targetStyle(.input).background)
            .frame(width: .fill, height: .fixed(1)).focusTarget(.input, in: focus)
          target(.output)
        }
        Row(gap: 1) {
          target(.text)
          target(.images)
        }
      }.padding(horizontal: 1).border("SOURCES / Enter previews a file", style: borderStyle())
        .background(palette.panel).navigationGroup(in: focus)
      Canvas(sourceDrawing).frame(width: .fill, height: .fixed(2))
        .padding(horizontal: 1).border("PREVIEW / " + label(sourceDrawing.selected), style: borderStyle(.sourcePreview))
        .background(palette.panel).focusTarget(.sourcePreview, in: focus)
      Row(gap: 1) {
        target(.build)
        target(.run)
      }
      .padding(horizontal: 1).border("ACTIONS / sample project", style: borderStyle())
      .background(palette.panel).navigationGroup(in: focus)
    }
  }

  var testsPage: some Block {
    Column(gap: 1) {
      Column(gap: 1) {
        target(.layoutSuite)
        target(.inputSuite)
        target(.unicodeSuite)
      }.padding(horizontal: 1).border("SUITES / Enter toggles selection", style: borderStyle())
        .background(palette.panel).navigationGroup(in: focus)
      Canvas(progressDrawing).frame(width: .fill, height: .fixed(2))
        .padding(horizontal: 1).border(
          "SAMPLE RUN / " + String(testProgress) + "%", style: borderStyle(tint: StudioPalette.mint)
        )
        .background(palette.panel)
      Row(gap: 1) {
        target(.runSuites)
        target(.selectAllSuites)
        target(.clearSuites)
      }.padding(horizontal: 1).border("RUNNER / simulated checks", style: borderStyle())
        .background(palette.panel).navigationGroup(in: focus)
    }
  }

  var docsPage: some Block {
    Column(gap: 1) {
      Row(gap: 1) {
        target(.gettingStarted)
        target(.layoutGuide)
        target(.inputGuide)
      }.padding(horizontal: 1).border("GUIDES / Enter opens", style: borderStyle())
        .background(palette.panel).navigationGroup(in: focus)
      Text(guide.text, style: Style(foreground: palette.text, background: palette.panel))
        .padding(horizontal: 1).border(guide.title, style: borderStyle(.article, tint: StudioPalette.sky))
        .background(palette.panel).focusTarget(.article, in: focus)
      Column {
        Text("Aa  é  漢字  👩🏽‍💻  🚀", style: Style(foreground: StudioPalette.coral, background: palette.panel, bold: true))
        Text("Unicode / graphemes / wide cells", style: Style(foreground: palette.muted, background: palette.panel))
      }.padding(horizontal: 1).border("TYPE SPECIMEN", style: borderStyle(.specimen, tint: StudioPalette.lilac))
        .background(palette.panel).focusTarget(.specimen, in: focus)
    }
  }

  var toolsPage: some Block {
    Column(gap: 1) {
      Column(gap: 1) {
        Column(gap: 1) {
          Row(gap: 1) {
            swatch(.cyanAccent, color: .cyan)
            swatch(.greenAccent, color: .green)
            swatch(.magentaAccent, color: .magenta)
          }
          Row(gap: 1) {
            swatch(.amberAccent, color: StudioPalette.amber)
            swatch(.coralAccent, color: StudioPalette.coral)
            swatch(.blueAccent, color: StudioPalette.sky)
          }
        }.navigationGroup(in: focus)
        Canvas(spectrum).frame(width: .fill, height: .fixed(1))
          .border("SPECTRUM / Enter remixes", style: borderStyle(.spectrum)).focusTarget(.spectrum, in: focus)
        InputBox(scratchpad, focused: editing && focus.isFocused(.scratchpad), style: targetStyle(.scratchpad))
          .padding(horizontal: 1).background(targetStyle(.scratchpad).background)
          .frame(width: .fill, height: .fixed(1)).focusTarget(.scratchpad, in: focus)
      }.padding(horizontal: 1).border("COLOR LAB / swatches + scratchpad", style: borderStyle())
        .background(palette.panel).navigationGroup(in: focus)
      Row(gap: 1) {
        target(.toggleTheme)
        target(.resetTools)
      }
      .padding(horizontal: 1).border("APPEARANCE", style: borderStyle())
      .background(palette.panel).navigationGroup(in: focus)
    }
  }

  var galleryPage: some Block {
    Column(gap: 1) {
      Row(gap: 1) {
        target(.aurora)
        target(.orbit)
        target(.dunes)
      }
      .padding(horizontal: 1).border("COLLECTION / procedural originals", style: borderStyle())
      .background(palette.panel).navigationGroup(in: focus)
      Canvas(artwork).focusTarget(.artwork, in: focus)
        .border(scene.title, style: borderStyle(.artwork, tint: StudioPalette.lilac))
        .background(palette.panel).frame(width: .fill, height: .fill)
      Column {
        target(.toggleKitty)
        Text(galleryStatus, style: Style(foreground: palette.muted, background: palette.background))
      }
    }
  }

  func swatch(_ id: NavigationTarget, color: Color) -> some Block {
    Text(
      (accent == color ? "● " : "○ ") + label(id),
      style: Style(
        foreground: focus.isFocused(id) ? palette.background : color,
        background: focus.isFocused(id) ? color : palette.panel, bold: true)
    )
    .padding(horizontal: 1).background(focus.isFocused(id) ? color : palette.panel)
    .frame(width: .fill, height: .fixed(1)).focusTarget(id, in: focus)
  }

  func target(_ id: NavigationTarget) -> some Block {
    Text(label(id), style: targetStyle(id)).padding(horizontal: 1).background(targetStyle(id).background)
      .frame(width: .fill, height: .fixed(1)).focusTarget(id, in: focus)
  }

  func targetStyle(_ id: NavigationTarget) -> Style {
    if focus.isFocused(id) { return Style(foreground: palette.background, background: accent, bold: true) }
    let selected =
      id.page == page || (id == .aurora && scene == .aurora) || (id == .orbit && scene == .orbit)
      || (id == .dunes && scene == .dunes)
    if selected { return Style(foreground: accent, background: palette.panel, bold: true, underlined: true) }
    return Style(foreground: palette.text, background: palette.panel)
  }

  func borderStyle(_ id: NavigationTarget? = nil, tint: Color? = nil) -> Style {
    Style(foreground: id != nil && focus.focusedID == id ? accent : tint ?? palette.border, background: palette.panel)
  }

  func label(_ id: NavigationTarget) -> String {
    if let page = id.page { return page.title }
    switch id {
    case .waveMetric: return "Wave"
    case .barsMetric: return "Bars"
    case .heatMetric: return "Heatmap"
    case .signal: return "Signal style"
    case .pauseAnimation: return animating ? "Pause" : "Resume"
    case .shuffleSignal: return "Remix"
    case .exploreGallery: return "Gallery →"
    case .layout: return "Layout.swift"
    case .drawing: return "Drawing.swift"
    case .input: return "Input"
    case .output: return "Output.swift"
    case .text: return "Text.swift"
    case .images: return "Images.swift"
    case .build: return "Build"
    case .run: return "Run"
    case .layoutSuite: return layoutSuite ? "[x] Layout / 88 checks" : "[ ] Layout / 88 checks"
    case .inputSuite: return inputSuite ? "[x] Input / 61 checks" : "[ ] Input / 61 checks"
    case .unicodeSuite: return unicodeSuite ? "[x] Unicode / 54 checks" : "[ ] Unicode / 54 checks"
    case .selectAllSuites: return "Select all"
    case .clearSuites: return "Clear"
    case .runSuites: return runningTests ? "Restart" : "Run selected"
    case .gettingStarted: return "Start"
    case .layoutGuide: return "Layout"
    case .inputGuide: return "Input"
    case .article: return guide.title
    case .cyanAccent: return "Cyan"
    case .greenAccent: return "Mint"
    case .magentaAccent: return "Orchid"
    case .amberAccent: return "Amber"
    case .coralAccent: return "Coral"
    case .blueAccent: return "Sky"
    case .scratchpad: return "Scratchpad"
    case .resetTools: return "Reset lab"
    case .toggleTheme: return lightTheme ? "Midnight theme" : "Paper theme"
    case .aurora: return "Aurora"
    case .orbit: return "Orbit"
    case .dunes: return "Dunes"
    case .artwork: return scene.title
    case .toggleKitty: return usesKitty ? "Images: Auto / Enter: Cells" : "Images: Cells / Enter: Auto"
    default: return "Explore"
    }
  }
}
