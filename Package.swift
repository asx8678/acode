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
            // ─── PARKED FROM COMMIT 45c1d76 FOR OPTION-B TUI RE-DERIVATION ───
            // The 16 files below are the uncommitted post-P0 TUI epic work
            // (RenderSink seam + alternate-screen UI) and the Phase-0 spike
            // (GUISink + SpikeApp). They live on disk and in git (commit
            // 45c1d76) but are excluded from this build so the engine + CLI
            // (line mode + one-shot) can compile green at the post-P0 seam.
            // They are NOT dead code: bead `swift-92m.9` (commit-message
            // recovery(2/5)) tracks their re-derivation, and the GUI effort
            // (Phase 2, separate epic) builds on top of the resulting
            // baseline. The matching TUI test (`GUISinkTests.swift`) is
            // excluded from `acodeTests` for the same reason.
            exclude: [
                "Capabilities.swift",
                "DiffView.swift",
                "GUISink.swift",
                "Highlight.swift",
                "KeyDecoder.swift",
                "KeyEvent.swift",
                "Metrics.swift",
                "Palette.swift",
                "ScreenRenderer.swift",
                "SpikeApp.swift",
                "Terminal.swift",
                "Theme.swift",
                "TUIApp.swift",
                "TUIModel.swift",
                "TUISink.swift",
                "TUIView.swift",
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "acodeTests",
            dependencies: ["acode"],
            path: "Tests/acodeTests",
            // PARKED: TUI + spike test excluded — see comment on the
            // `acode` target above. Re-enable alongside the source set
            // when bead `swift-92m.9` (re-derive parked TUI) is worked.
            exclude: [
                "GUISinkTests.swift",
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
