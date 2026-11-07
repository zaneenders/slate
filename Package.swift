// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .strictMemorySafety(),
  .treatAllWarnings(as: .error),
  .enableExperimentalFeature("Lifetimes")
]
let package = Package(
  name: "Slate",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "Slate", targets: ["Slate"]),
    .library(name: "SlateComposition", targets: ["SlateComposition"]),
    .library(name: "SlateUI", targets: ["SlateUI"]),
    .library(name: "SlateTerminal", targets: ["SlateTerminal"]),
    .library(name: "SlateApplication", targets: ["SlateApplication"]),
    .library(name: "CTerminalSignals", targets: ["CTerminalSignals"]),
    .executable(name: "slate-demo", targets: ["SlateDemo"])
  ],
  dependencies: [.package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.5")],
  targets: [
    .target(
      name: "Slate", dependencies: ["SlateComposition", "SlateUI", "SlateTerminal", "SlateApplication"],
      swiftSettings: swiftSettings),
    .target(
      name: "SlateComposition", dependencies: [.product(name: "BasicContainers", package: "swift-collections")],
      swiftSettings: swiftSettings + [.treatWarning("EmbeddedRestrictions", as: .warning)]),
    .target(
      name: "SlateUI",
      dependencies: ["SlateComposition", .product(name: "BasicContainers", package: "swift-collections")],
      swiftSettings: swiftSettings + [.treatWarning("EmbeddedRestrictions", as: .warning)]),
    .target(
      name: "SlateTerminal", dependencies: ["SlateUI", .product(name: "BasicContainers", package: "swift-collections")],
      swiftSettings: swiftSettings + [.treatWarning("EmbeddedRestrictions", as: .warning)]),
    .target(
      name: "SlateApplication",
      dependencies: [
        "SlateTerminal", "CTerminalSignals", .product(name: "BasicContainers", package: "swift-collections")
      ],
      swiftSettings: swiftSettings + [.treatWarning("EmbeddedRestrictions", as: .warning)]),
    .target(name: "CTerminalSignals"),
    .executableTarget(
      name: "SlateDemo", dependencies: ["Slate"], path: "Examples/SlateDemo", swiftSettings: swiftSettings),
    .executableTarget(
      name: "SlateSignalFixture", dependencies: ["SlateApplication"], path: "Tests/SlateSignalFixture",
      swiftSettings: swiftSettings),
    .target(name: "CIOTestSupport", path: "Tests/CIOTestSupport"),
    .testTarget(name: "SlateUITests", dependencies: ["SlateUI"], swiftSettings: swiftSettings),
    .testTarget(
      name: "SlateTests",
      dependencies: [
        "Slate", "SlateComposition", "SlateUI", "SlateTerminal", "SlateApplication", "CIOTestSupport",
        "SlateSignalFixture"
      ],
      swiftSettings: swiftSettings,
      linkerSettings: [
        .unsafeFlags(
          ["-Xlinker", "--wrap=read", "-Xlinker", "--wrap=write", "-Xlinker", "--wrap=poll"], .when(platforms: [.linux])
        )
      ])
  ],
  swiftLanguageModes: [.v6]
)
