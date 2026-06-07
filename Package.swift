// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "acode",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "acode",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/acode",
            // The 16-file `exclude` list previously parked the TUI epic
            // work (RenderSink seam + alternate-screen UI) and the Phase-0
            // GUI spike. They have all been re-derived on this branch and
            // the GUI spike was removed entirely; both the TUI restore and
            // (in their absence) the engine compile together as a single
            // target. No excludes are needed.
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "acodeTests",
            dependencies: ["acode"],
            path: "Tests/acodeTests",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
