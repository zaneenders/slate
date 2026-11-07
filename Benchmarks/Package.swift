// swift-tools-version: 6.4

import PackageDescription

// Standalone Linux/Glibc tools. Allocator interposition never enters the app or tests.
let hooks: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "--export-dynamic"])]
let package = Package(
  name: "SlateBenchmarks",
  products: [
    .executable(name: "slate-benchmark", targets: ["slate-benchmark"]),
    .library(name: "AllocationProbe", targets: ["AllocationProbe"])
  ],
  dependencies: [.package(name: "Slate", path: "..")],
  targets: [
    .target(name: "AllocationProbe"),
    .executableTarget(
      name: "slate-benchmark",
      dependencies: [
        .product(name: "SlateUI", package: "Slate"),
        .product(name: "SlateTerminal", package: "Slate"),
        "AllocationProbe"
      ],
      swiftSettings: [
        .strictMemorySafety(), .treatAllWarnings(as: .error), .enableExperimentalFeature("Lifetimes")
      ],
      linkerSettings: hooks)
  ],
  swiftLanguageModes: [.v6]
)
