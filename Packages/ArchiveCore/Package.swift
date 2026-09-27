// swift-tools-version: 5.9
// ArchiveCore — the archive engine: store, index, parsers, import, export, receipts, layout.
// Imports nothing from the app. The app and its tests import it with
// `@testable import ArchiveCore` (the target is built with -enable-testing), so
// the module's internal API is usable without a public-annotation pass; hardening
// the public surface is the follow-up recorded in MAILIN_3_0_TODO.md C-1.
import PackageDescription

let package = Package(
    name: "ArchiveCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ArchiveCore", targets: ["ArchiveCore"])],
    targets: [
        .target(name: "ArchiveCore",
                path: "Sources/ArchiveCore",
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        // Runs UNSANDBOXED under `swift test` (no host app), which is what the
        // fault-injection rows need: the sandboxed app cannot write to a
        // mounted disk image at all.
        .testTarget(name: "ArchiveCoreTests",
                    dependencies: ["ArchiveCore"],
                    path: "Tests/ArchiveCoreTests")
    ]
)
