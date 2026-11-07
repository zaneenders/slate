// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .strictMemorySafety(),
  .treatAllWarnings(as: .error),
  .enableExperimentalFeature("Lifetimes"),
  .treatWarning("EmbeddedRestrictions", as: .error)
]

let package = Package(
  name: "slate",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "Slate", targets: ["Slate"]),
    .library(name: "SlateComposition", targets: ["SlateComposition"]),
    .library(name: "SlateUI", targets: ["SlateUI"]),
    .library(name: "SlateTerminal", targets: ["SlateTerminal"]),
    .library(name: "SlateApplication", targets: ["SlateApplication"]),
    .executable(name: "slate-demo", targets: ["SlateDemo"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.5")
  ],
  targets: [
    // Demo
    .executableTarget(
      name: "SlateDemo",
      dependencies: ["Slate"],
      path: "Examples/SlateDemo",
      swiftSettings: swiftSettings
    ),
    // Libraries
    .target(
      name: "Slate",
      dependencies: [
        "SlateComposition",
        "SlateUI",
        "SlateTerminal",
        "SlateApplication"
      ],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "SlateComposition",
      dependencies: [
        .product(name: "BasicContainers", package: "swift-collections")
      ],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "SlateUI",
      dependencies: [
        "SlateComposition",
        .product(name: "BasicContainers", package: "swift-collections")
      ],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "SlateTerminal",
      dependencies: [
        "SlateUI",
        .product(name: "BasicContainers", package: "swift-collections")
      ],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "SlateApplication",
      dependencies: [
        "SlateTerminal",
        .product(name: "BasicContainers", package: "swift-collections")
      ],
      swiftSettings: swiftSettings
    ),

    // Test support
    .executableTarget(
      name: "SlateSignalFixture",
      dependencies: ["SlateApplication"],
      path: "Tests/SlateSignalFixture"
    ),
    .target(
      name: "CIOTestSupport",
      path: "Tests/CIOTestSupport"
    ),

    // Tests
    .testTarget(
      name: "SlateUITests",
      dependencies: ["SlateUI"]
    ),
    .testTarget(
      name: "SlateTests",
      dependencies: [
        "Slate",
        "SlateComposition",
        "SlateUI",
        "SlateTerminal",
        "SlateApplication",
        "CIOTestSupport",
        "SlateSignalFixture"
      ],
      linkerSettings: [
        .unsafeFlags(
          [
            "-Xlinker", "--wrap=read",
            "-Xlinker", "--wrap=write",
            "-Xlinker", "--wrap=poll"
          ],
          .when(platforms: [.linux])
        )
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
