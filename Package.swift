// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftServe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Platform-agnostic brains: parsing + scoring + mood. Reused later by a CLI / GitHub Action.
        .library(name: "SwiftServeCore", targets: ["SwiftServeCore"]),
        // The web front door. Dogfoods Hummingbird.
        .executable(name: "SwiftServeServer", targets: ["SwiftServeServer"]),
        // The terminal/CI front door. Same Core, same canonical JSON.
        .executable(name: "swiftserve", targets: ["SwiftServeCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Source-level scanning only. Pinned to the 603.x line, which tracks the
        // Swift 6.3 toolchain. SwiftParser is standalone (no ABI lock to the
        // installed compiler); the pin keeps it parsing current syntax. Isolated
        // to SwiftServeSource so Core/Scan stay dependency-light.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        // Core has ZERO external dependencies — pure Swift + Foundation, macOS + Linux.
        .target(
            name: "SwiftServeCore"
        ),
        // Pillar 2: private-API detection. Pure, no I/O, no process-spawning.
        // Depends on Core only to reuse the Swiftee `Mood` brand enum.
        .target(
            name: "SwiftServeScan",
            dependencies: ["SwiftServeCore"]
        ),
        // Slice 4: build-time pointers. Pure — parses type-check-timing warning
        // TEXT into records and ranks them into actionable [Pointer]. No I/O, no
        // process-spawning (the CLI drives `swift build`); no dependency on the
        // private-API Scan pillar — this is *suggestions*, not *detection*. Core
        // only, for the Swiftee `Mood` brand enum.
        .target(
            name: "SwiftServeBuild",
            dependencies: ["SwiftServeCore"]
        ),
        // Slice 3: source-level extraction for the private-API pillar. Its sole
        // job is turning source text into candidate sites (call kind +
        // string-literal argument + file:line); the privacy verdict stays in
        // SwiftServeScan, so all three surfaces share one judgment.
        .target(
            name: "SwiftServeSource",
            dependencies: [
                "SwiftServeScan",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        // Capability search, pure pillar: surface models, platform resolution,
        // capability records, taxonomy, and the grounding validator. Core only —
        // no SwiftSyntax, no I/O. This is where every capability verdict lives.
        .target(
            name: "SwiftServeCapability",
            dependencies: ["SwiftServeCore"]
        ),
        // Capability search, extraction layer: the second (and only other)
        // SwiftSyntax target. Turns package source into SwiftServeCapability's
        // SurfaceDecl values — public API surface × #if guards × @available.
        // Extracts only; resolution and verdicts stay in SwiftServeCapability.
        .target(
            name: "SwiftServeSurface",
            dependencies: [
                "SwiftServeCapability",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "SwiftServeServer",
            dependencies: [
                "SwiftServeCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        // The static-site brain: capability records + taxonomy → the pages,
        // API JSON, and (later) badges under Public/. Templates are Swift
        // string interpolation — no engine, testable, deterministic output.
        .target(
            name: "SwiftServeSite",
            dependencies: ["SwiftServeCore", "SwiftServeCapability"]
        ),
        // The generator executable: `swift run SwiftServeSiteGen --out Public`.
        // Repo-internal tooling — not installed with the CLI.
        .executableTarget(
            name: "SwiftServeSiteGen",
            dependencies: [
                "SwiftServeSite",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SwiftServeSiteTests",
            dependencies: ["SwiftServeSite"]
        ),
        .executableTarget(
            name: "SwiftServeCLI",
            dependencies: [
                "SwiftServeCore",
                "SwiftServeScan",
                "SwiftServeSource",
                "SwiftServeBuild",
                "SwiftServeCapability",
                "SwiftServeSurface",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "SwiftServeCoreTests",
            dependencies: ["SwiftServeCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SwiftServeScanTests",
            dependencies: ["SwiftServeScan"],
            resources: [.copy("Fixtures")]
        ),
        // Source parser tests feed source STRINGS (no disk) — proving the AST does
        // real work (e.g. a Selector("_x") in a comment is not a finding).
        .testTarget(
            name: "SwiftServeSourceTests",
            dependencies: ["SwiftServeSource"]
        ),
        // Build pillar tests feed raw warning TEXT and structured records — never a
        // real build — proving parse + rank + verdict in isolation.
        .testTarget(
            name: "SwiftServeBuildTests",
            dependencies: ["SwiftServeBuild"]
        ),
        // Surface extraction tests feed source STRINGS (no disk) — proving the
        // #if/#elseif/#else negation semantics, access rules, and @available
        // parsing on exact, minimal inputs.
        .testTarget(
            name: "SwiftServeSurfaceTests",
            dependencies: ["SwiftServeSurface"]
        ),
        // Capability pillar tests: resolver truth tables (Kleene logic, the
        // Catalyst subtlety), module table behavior — pure data in, data out.
        .testTarget(
            name: "SwiftServeCapabilityTests",
            dependencies: ["SwiftServeCapability"]
        ),
    ]
)
