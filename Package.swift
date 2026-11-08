// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .strictMemorySafety(),
  .treatAllWarnings(as: .error),
  .enableExperimentalFeature("Lifetimes"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("ApproachableConcurrency"),
  .treatWarning("EmbeddedRestrictions", as: .error),
  .treatWarning("ExplicitSendable", as: .error),
  .treatWarning("PerformanceHints", as: .warning),
  .treatWarning("UntypedThrows", as: .error)  // Must succeed PerformanceHints
]

let package = Package(
  name: "slate",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "Slate", targets: ["Slate"]),
    .executable(name: "slate-document-demo", targets: ["SlateDocumentDemo"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.5"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.0")
  ],
  targets: [
    // Demo
    .executableTarget(
      name: "SlateDocumentDemo",
      dependencies: [
        "Slate",
        .product(name: "BasicContainers", package: "swift-collections"),
        .product(name: "_RopeModule", package: "swift-collections"),
        .product(name: "SystemPackage", package: "swift-system")
      ],
      path: "Examples/SlateDocumentDemo",
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
      exclude: ["UnicodeWidth/Unicode-LICENSE.txt"],
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
        .product(name: "BasicContainers", package: "swift-collections"),
        .product(name: "SystemPackage", package: "swift-system")
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
      name: "SlateDocumentDemoTests",
      dependencies: ["SlateDocumentDemo", "Slate"],
      swiftSettings: [.enableExperimentalFeature("Lifetimes")]
    ),
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
