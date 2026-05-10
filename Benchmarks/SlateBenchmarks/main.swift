import CollectionsBenchmark
import SlateCore

// MARK: - Entry point

var benchmark = Benchmark(title: "Slate Benchmarks")
benchmark.registerSlateGenerators()
benchmark.addSlateBenchmarks()
benchmark.main()
