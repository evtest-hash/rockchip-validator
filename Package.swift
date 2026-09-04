// swift-tools-version: 5.9
// Rockchip material validation bench, second iteration.
//
// Two targets on purpose. `ValidationCore` holds the model, the engine, the items and the report
// and **must not import SwiftUI** — `CoreHasNoUITests` enforces that. In the first iteration the
// interface lived inside the core library, which made `Bench` `@MainActor` because a view observed
// it, which in turn pinned the whole engine to the main actor. The boundary is the point; the
// process model is not — the CLI still runs every bench concurrently in one process.
import PackageDescription

let package = Package(
    name: "RockchipValidator",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ValidationCore",
            path: "Sources/ValidationCore",
            resources: [.copy("Resources/payloads")]
        ),
        // The interface, in its own target, depending on the core and never the other way round.
        .executableTarget(
            name: "RockchipValidator",
            dependencies: ["ValidationCore"],
            path: "Sources/RockchipValidator"
        ),
        .executableTarget(
            name: "rkval",
            dependencies: ["ValidationCore"],
            path: "Sources/rkval"
        ),
        .testTarget(
            name: "ValidationCoreTests",
            // The interface too: its rules are behaviour, not text. Three tests here scan the UI
            // sources as strings because they had no other way in, which is a poor substitute for
            // running the thing.
            dependencies: ["ValidationCore", "RockchipValidator"],
            path: "Tests/ValidationCoreTests"
        ),
    ]
)
