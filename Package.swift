// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeNetworkGuard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BoundTransport", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "GuardCore"),
        .executableTarget(name: "guardnetd", dependencies: ["GuardCore", "BoundTransport"]),
        .executableTarget(name: "guardrelay"),
        .target(name: "GuardConfine"),
        .executableTarget(name: "guardrun", dependencies: ["GuardConfine"]),
        .executableTarget(name: "guardshell", dependencies: ["GuardConfine"]),
        .executableTarget(name: "guardcheck", dependencies: ["BoundTransport"]),
        .executableTarget(name: "guardwatch"),
        .executableTarget(name: "ClaudeNetworkGuard", dependencies: ["BoundTransport", "GuardCore"]),
        .testTarget(name: "ClaudeNetworkGuardTests", dependencies: ["ClaudeNetworkGuard", "GuardCore"])
    ]
)
