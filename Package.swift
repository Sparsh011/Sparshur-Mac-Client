// swift-tools-version: 6.0
import PackageDescription

// A test harness for the same platform and model sources Xcode compiles into the app.
// The reference CLI compiles Core/PairedProtocol.swift and StrictJSON.swift
// directly from this same source tree. There are no remote dependencies.
let package = Package(
  name: "SparshurPlatform",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "SparshurPlatform", path: "Sparshur",
      exclude: [
        "Assets.xcassets", "ContentView.swift", "SparshurApp.swift", "Sparshur.entitlements",
        "Views", "AppEntry.swift",
      ],
      sources: ["Services", "App", "Core", "Networking"]),
    .testTarget(
      name: "SparshurPlatformTests", dependencies: ["SparshurPlatform"], path: "Tests",
      resources: [.copy("Fixtures")]),
  ]
)
