// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "WhiplashCore",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "WhiplashCore", targets: ["WhiplashCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/AnyLanguageModel", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "WhiplashCore",
            dependencies: ["AnyLanguageModel"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
