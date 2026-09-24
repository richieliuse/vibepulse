// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibePulseBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibePulseBar", targets: ["VibePulseBar"]),
        .executable(name: "vibepulse-statusline", targets: ["vibepulse-statusline"]),
    ],
    targets: [
        .target(name: "VibePulseSupport"),
        .target(name: "VibePulseState", dependencies: ["VibePulseSupport"]),
        .target(name: "VibePulseProviders", dependencies: ["VibePulseState"]),
        .target(name: "VibePulseAgents", dependencies: ["VibePulseState"]),
        .target(name: "VibePulseRelay", dependencies: ["VibePulseAgents", "VibePulseSupport"]),
        .target(name: "VibePulseServer", dependencies: ["VibePulseProviders", "VibePulseAgents", "VibePulseRelay"]),
        .executableTarget(name: "vibepulse-statusline", dependencies: ["VibePulseState"]),
        .target(name: "VibePulseBarCore"),
        .executableTarget(name: "VibePulseBar", dependencies: ["VibePulseBarCore", "VibePulseServer"]),
        .testTarget(name: "VibePulseBarCoreTests", dependencies: ["VibePulseBarCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "VibePulseEngineTests", dependencies: ["VibePulseServer", "VibePulseState"]),
    ]
)
