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
    .library(name: "SlateGamepad", targets: ["SlateGamepad"]),
    .executable(name: "starter", targets: ["SlateStarter"]),
    .executable(name: "navigation", targets: ["SlateNavigationDemo"]),
    .executable(name: "document", targets: ["SlateDocumentDemo"]),
    .executable(name: "graphics", targets: ["SlateGraphicsDemo"]),
    .executable(name: "kitty-graphics", targets: ["SlateKittyGraphicsDemo"]),
    .executable(name: "render-benchmark", targets: ["SlateRenderBenchmark"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.6"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.9.0"),
    .package(
      url: "https://github.com/zaneenders/swift-zlib.git",
      revision: "d2790e2e0bdac0d48dd622a8b97b8c20f8807c1d")
  ],
  targets: [
    .executableTarget(
      name: "SlateRenderBenchmark",
      dependencies: ["SlateTerminal", "SlateUI"],
      path: "Benchmarks/SlateRenderBenchmark",
      swiftSettings: swiftSettings
    ),
    // Demo
    .executableTarget(
      name: "SlateNavigationDemo",
      dependencies: ["Slate", "SlateGamepad"],
      path: "Examples/SlateNavigationDemo",
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "SlateStarter",
      dependencies: ["Slate"],
      path: "Examples/SlateStarter",
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "SlateGraphicsDemo",
      dependencies: ["Slate"],
      path: "Examples/SlateGraphicsDemo",
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "SlateKittyGraphicsDemo",
      dependencies: ["Slate"],
      path: "Examples/SlateKittyGraphicsDemo",
      swiftSettings: swiftSettings
    ),
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
    // Libraries: application lifecycle -> terminal extensions/backend -> UI composition and drawing.
    .target(
      name: "SlateGamepad",
      dependencies: [
        "SlateUI",
        .target(name: "CLinuxGamepad", condition: .when(platforms: [.linux])),
        .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux]))
      ],
      swiftSettings: swiftSettings,
      linkerSettings: [.linkedFramework("GameController", .when(platforms: [.macOS]))]
    ),
    // Only Linux ioctl macros need a C boundary; ownership stays in Swift.
    .target(name: "CLinuxGamepad"),
    .target(
      name: "Slate",
      dependencies: [
        "SlateUI",
        "SlateTerminal",
        "SlateKittyGraphics",
        "SlateApplication"
      ],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "SlateUI",
      dependencies: [
        .product(name: "BasicContainers", package: "swift-collections")
      ],
      exclude: ["Unicode/Unicode-LICENSE.txt"],
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
      name: "SlateKittyGraphics",
      dependencies: [
        "SlateTerminal",
        "SlateUI",
        .product(name: "Zlib", package: "swift-zlib")
      ],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "SlateApplication",
      dependencies: [
        "SlateTerminal",
        "SlateKittyGraphics",
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
      path: "Tests/CIOTestSupport",
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
    ),
    .target(
      name: "SlateTestSupport",
      path: "Tests/SlateTestSupport"
    ),

    // Tests
    .testTarget(
      name: "SlateGamepadTests",
      dependencies: [
        "SlateGamepad", "CIOTestSupport",
        .target(name: "CLinuxGamepad", condition: .when(platforms: [.linux])),
        .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux]))
      ],
      swiftSettings: [.enableExperimentalFeature("Lifetimes")]
    ),
    .testTarget(
      name: "SlateNavigationDemoTests",
      dependencies: ["SlateNavigationDemo", "Slate", "SlateGamepad", "SlateTestSupport"]
    ),
    .testTarget(
      name: "SlateKittyGraphicsDemoTests",
      dependencies: ["SlateKittyGraphicsDemo", "Slate", "SlateTestSupport", "CIOTestSupport"]
    ),
    .testTarget(
      name: "SlateGraphicsDemoTests",
      dependencies: ["SlateGraphicsDemo", "Slate", "CIOTestSupport"],
      swiftSettings: [.enableExperimentalFeature("Lifetimes")]
    ),
    .testTarget(
      name: "SlateDocumentDemoTests",
      dependencies: ["SlateDocumentDemo", "Slate"],
      swiftSettings: [.enableExperimentalFeature("Lifetimes")]
    ),
    .testTarget(
      name: "SlateUITests",
      dependencies: ["SlateUI", "CIOTestSupport"]
    ),
    .testTarget(
      name: "SlateTerminalTests",
      dependencies: ["SlateTerminal", "SlateTestSupport", "CIOTestSupport"]
    ),
    .testTarget(
      name: "SlateKittyGraphicsTests",
      dependencies: [
        "SlateKittyGraphics",
        "SlateTerminal",
        "SlateTestSupport",
        "CIOTestSupport",
        .product(name: "Zlib", package: "swift-zlib")
      ]
    ),
    .testTarget(
      name: "SlateApplicationTests",
      dependencies: [
        "SlateApplication",
        "SlateTestSupport",
        "CIOTestSupport",
        "SlateSignalFixture"
      ]
    ),
    .testTarget(
      name: "SlateTests",
      dependencies: ["Slate", "SlateTestSupport"]
    )
  ],
  swiftLanguageModes: [.v6]
)
