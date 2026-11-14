import Slate

enum NavigationTarget: Hashable, Sendable {
  case overview, sources, tests, docs, tools, gallery
  case waveMetric, barsMetric, heatMetric, signal, pauseAnimation, shuffleSignal, exploreGallery
  case layout, drawing, input, output, text, images, sourcePreview
  case build, run
  case layoutSuite, inputSuite, unicodeSuite, selectAllSuites, clearSuites, runSuites
  case gettingStarted, layoutGuide, inputGuide, article, specimen
  case cyanAccent, greenAccent, magentaAccent, amberAccent, coralAccent, blueAccent
  case scratchpad, resetTools, toggleTheme, spectrum
  case aurora, orbit, dunes, artwork, toggleKitty

  var page: NavigationPage? {
    switch self {
    case .overview: return .overview
    case .sources: return .sources
    case .tests: return .tests
    case .docs: return .docs
    case .tools: return .tools
    case .gallery: return .gallery
    default: return nil
    }
  }
}

enum NavigationPage: Equatable, Sendable {
  case overview, sources, tests, docs, tools, gallery

  var title: String {
    switch self {
    case .overview: return "Overview"
    case .sources: return "Sources"
    case .tests: return "Tests"
    case .docs: return "Docs"
    case .tools: return "Color lab"
    case .gallery: return "Gallery"
    }
  }
}

enum NavigationGuide {
  case gettingStarted, layout, input

  var title: String {
    switch self {
    case .gettingStarted: return "Getting started"
    case .layout: return "Layout guide"
    case .input: return "Input guide"
    }
  }

  var text: String {
    switch self {
    case .gettingStarted:
      return
        "Enter or click a sidebar item to open a page.\nArrows follow the visible groups.\nTry the live charts, color lab, and gallery.\nResize the terminal to explore reflow."
    case .layout:
      return
        "Rows arrange content side by side.\nColumns stack content from top to bottom.\nGroups keep related controls together.\nAt an edge, arrows find a neighboring region."
    case .input:
      return
        "Enter starts editing an input field.\nLeft and Right then move the caret.\nEscape returns to spatial navigation.\nCtrl-Q quits from either mode."
    }
  }
}

struct StudioPalette {
  var light = false
  var background: Color { light ? .rgb(231, 237, 245) : .rgb(10, 15, 26) }
  var panel: Color { light ? .rgb(248, 250, 255) : .rgb(19, 27, 43) }
  var text: Color { light ? .rgb(28, 43, 65) : .rgb(223, 233, 250) }
  var muted: Color { light ? .rgb(82, 101, 128) : .rgb(143, 164, 195) }
  var border: Color { light ? .rgb(156, 174, 200) : .rgb(48, 67, 97) }
  static let sky = Color.rgb(93, 185, 255)
  static let mint = Color.rgb(88, 225, 180)
  static let lilac = Color.rgb(185, 145, 255)
  static let amber = Color.rgb(255, 204, 111)
  static let coral = Color.rgb(255, 136, 155)
}
