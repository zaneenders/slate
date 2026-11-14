import Foundation
import SlateTerminal
import SlateUI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private enum BenchmarkError: Error {
  case arguments
  case io(IOError)
  case screen(ScreenError)
  case surface(SurfaceError)
}

@main
struct SlateRenderBenchmark {
  static func main() {
    do throws(BenchmarkError) {
      let options = try Options(Array(CommandLine.arguments.dropFirst()))
      if options.help {
        print("Usage: render-benchmark [--iterations 1...100000] [--warmup 1...10000]")
        return
      }
      var results: [Measurement] = []
      try measure(options, into: &results)
      // Formatting and JSON allocation happen after every measured loop.
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(results)
        print(String(decoding: data, as: UTF8.self))
      } catch {
        diagnostics("Unable to encode benchmark results.")
        exit(EXIT_FAILURE)
      }
    } catch {
      diagnostics("Benchmark failed: \(error). Use --help for usage.")
      exit(EXIT_FAILURE)
    }
  }

  private static func diagnostics(_ text: String) {
    if let output = try? Output(fileDescriptor: STDERR_FILENO) {
      try? output.writeAll((text + "\n").utf8Span.span)
    }
  }

  private static func measure(_ options: Options, into results: inout [Measurement]) throws(BenchmarkError) {
    let descriptor = unsafe open("/dev/null", O_WRONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .io(.write(errno: errno, bytesWritten: 0)) }
    defer { _ = close(descriptor) }
    let output: Output
    do throws(IOError) { output = try Output(fileDescriptor: descriptor) } catch { throw .io(error) }
    for size in [TerminalSize(columns: 80, rows: 24), .init(columns: 240, rows: 80), .init(columns: 512, rows: 256)] {
      for scenario in Scenario.allCases {
        results.append(try measure(scenario, size: size, options: options, output: output))
      }
    }
  }

  private static func measure(
    _ scenario: Scenario, size: TerminalSize, options: Options, output: borrowing Output
  ) throws(BenchmarkError) -> Measurement {
    let workload = Workload(scenario: scenario, size: size)
    var surface: Surface
    var screen: Screen
    do throws(SurfaceError) { surface = try Surface(maximumSize: size) } catch { throw .surface(error) }
    do throws(ScreenError) { screen = try Screen(maximumSize: size) } catch { throw .screen(error) }
    let clock = ContinuousClock()
    var changedCells = 0
    var outputBytes = 0
    var checksum = 0
    let renderDuration: Duration
    do throws(SurfaceError) {
      for frame in 0..<options.warmup {
        workload.frame = frame
        try surface.render(size: size) { Canvas(workload) }
      }
      let start = clock.now
      for frame in options.warmup..<(options.warmup + options.iterations) {
        workload.frame = frame
        try surface.render(size: size) { Canvas(workload) }
        // Keep each rendered result observable even in an optimized build.
        checksum &+= Int(surface.cell(x: 0, y: 0)!.glyph.scalar.value)
      }
      renderDuration = start.duration(to: clock.now)
    } catch { throw .surface(error) }
    let drawDuration: Duration
    do throws(ScreenError) {
      for frame in 0..<options.warmup {
        workload.frame = frame
        if scenario == .fullRepaint { screen.invalidate() }
        try screen.draw(size: size, to: output) { Canvas(workload) }
      }
      let start = clock.now
      for frame in options.warmup..<(options.warmup + options.iterations) {
        workload.frame = frame
        if scenario == .fullRepaint { screen.invalidate() }
        let statistics = try screen.draw(size: size, to: output) { Canvas(workload) }
        changedCells += statistics.changedCells
        outputBytes += statistics.outputBytes
      }
      drawDuration = start.duration(to: clock.now)
    } catch { throw .screen(error) }
    return Measurement(
      scenario: scenario.rawValue, columns: size.columns, rows: size.rows,
      iterations: options.iterations, warmup: options.warmup,
      renderNanosecondsPerFrame: nanoseconds(renderDuration) / Double(options.iterations),
      drawNanosecondsPerFrame: nanoseconds(drawDuration) / Double(options.iterations),
      changedCellsPerFrame: Double(changedCells) / Double(options.iterations),
      outputBytesPerFrame: Double(outputBytes) / Double(options.iterations), checksum: checksum)
  }
}

private struct Options {
  var iterations = 1_000
  var warmup = 50
  var help = false

  init(_ arguments: [String]) throws(BenchmarkError) {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--help" {
        help = true
        index += 1
        continue
      }
      guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else { throw .arguments }
      switch argument {
      case "--iterations" where (1...100_000).contains(value): iterations = value
      case "--warmup" where (1...10_000).contains(value): warmup = value
      default: throw .arguments
      }
      index += 2
    }
  }
}

private enum Scenario: String, CaseIterable {
  case unchanged, sparse, scrolling
  case fullRepaint = "full-repaint"
}

private struct Measurement: Encodable {
  let scenario: String
  let columns: Int
  let rows: Int
  let iterations: Int
  let warmup: Int
  let renderNanosecondsPerFrame: Double
  let drawNanosecondsPerFrame: Double
  let changedCellsPerFrame: Double
  let outputBytesPerFrame: Double
  let checksum: Int
}

private func nanoseconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) * 1_000_000_000 + Double(components.attoseconds) / 1_000_000_000
}

private final class Workload: CanvasDrawing {
  let scenario: Scenario
  private let lines: [String]
  private let base = Cell(Glyph(".")!, style: Style(foreground: .cyan))
  private let alternate = Cell(Glyph("x")!, style: Style(foreground: .yellow))
  var frame = 0

  init(scenario: Scenario, size: TerminalSize) {
    self.scenario = scenario
    lines = (0..<(size.rows + 1)).map { row in
      String(decoding: (0..<size.columns).map { UInt8(0x21 + (row * 7 + $0) % 90) }, as: UTF8.self)
    }
  }

  func paint(in frame: inout Frame) {
    switch scenario {
    case .unchanged: frame.fill(frame.area, with: base)
    case .sparse:
      frame.fill(frame.area, with: base)
      frame[frame.area.width / 2, frame.area.height / 2] = self.frame.isMultiple(of: 2) ? base : alternate
    case .scrolling:
      for row in 0..<frame.area.height {
        frame.text(
          lines[(self.frame + row) % lines.count],
          in: Rect(y: row, width: frame.area.width, height: 1))
      }
    case .fullRepaint: frame.fill(frame.area, with: self.frame.isMultiple(of: 2) ? base : alternate)
    }
  }
}
