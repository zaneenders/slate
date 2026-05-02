// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "slate",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "SlateDemo", targets: ["SlateDemo"]),
    .library(name: "SlateCore", targets: ["SlateCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.4.1"),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.3"),
  ],
  targets: [
    .target(
      name: "SlateCore",
      dependencies: [
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "BasicContainers", package: "swift-collections"),
      ],
      swiftSettings: [
        .treatAllWarnings(as: .error),
        .strictMemorySafety(),
      ]),
    .executableTarget(
      name: "SlateDemo",
      dependencies: [
        "SlateCore"
      ],
      swiftSettings: [
        .treatAllWarnings(as: .error),
        .strictMemorySafety(),
      ]),
    .testTarget(
      name: "SlateCoreTests",
      dependencies: [
        "SlateCore"
      ],
      swiftSettings: [
        .treatAllWarnings(as: .error),
        .strictMemorySafety(),
      ]),
  ]
)
