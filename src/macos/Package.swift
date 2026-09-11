// swift-tools-version: 6.2
import PackageDescription

// Phase 0 spike layout — see PLAN.md. Zero external package dependencies:
// swift-testing ships in the Xcode Command Line Tools toolchain already, and
// this machine has no Xcode, so nothing beyond CLT can be relied on.
let package = Package(
    name: "sbx-helper",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        // Pure logic — Foundation only, no Process/AppKit/SwiftUI. Split out
        // so `swift test` can exercise it without linking against the `@main`
        // executable target (SwiftPM can't cleanly test an executable target
        // without Xcode).
        .target(
            name: "SbxKit",
            path: "Sources/SbxKit"
        ),
        // Process spawning, tool location, terminal launch, clipboard/Finder,
        // config persistence — everything that actually shells out. Depends
        // on SbxKit for argv assembly/JSON parsing/config codec; see PLAN.md
        // Phase 2.
        .target(
            name: "SbxServices",
            dependencies: ["SbxKit"],
            path: "Sources/SbxServices"
        ),
        // @Observable models (AppModel, BuilderModel) + ScanService actor.
        // Imports SbxKit/SbxServices/Observation but never SwiftUI, so it
        // links into a test target — SwiftPM can't test an executable
        // target, and PLAN.md forbids tests that import SwiftUI (no
        // ViewInspector, no XCUITest without Xcode). See PLAN.md Phase 3.
        .target(
            name: "SbxAppCore",
            dependencies: ["SbxKit", "SbxServices"],
            path: "Sources/SbxAppCore"
        ),
        .executableTarget(
            name: "SbxHelperApp",
            dependencies: ["SbxKit", "SbxServices", "SbxAppCore"],
            path: "Sources/SbxHelperApp",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "SbxKitTests",
            dependencies: ["SbxKit"],
            path: "Tests/SbxKitTests"
        ),
        .testTarget(
            name: "SbxAppCoreTests",
            // SbxKit/SbxServices are used directly by several test files
            // (TreeNode, ConfigStore, ...), not just transitively through
            // SbxAppCore — declare them explicitly rather than relying on
            // SwiftPM leaving their module paths in the search path.
            dependencies: ["SbxAppCore", "SbxKit", "SbxServices"],
            path: "Tests/SbxAppCoreTests"
        ),
        .testTarget(
            name: "SbxServicesTests",
            dependencies: ["SbxServices"],
            path: "Tests/SbxServicesTests",
            // Not a `resources:` entry deliberately — ShimHarness locates
            // this file itself via `#filePath` (see its doc comment / the
            // Tests/SbxKitTests/Support/ParityCorpus.swift precedent for
            // why Bundle.module is avoided here). `exclude` just tells
            // SwiftPM this isn't a stray, unhandled source file.
            exclude: ["Fixtures/sbx-shim.sh"]
        ),
    ]
)
