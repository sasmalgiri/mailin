// swift-tools-version: 6.0
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
        // §3-P1: Swift 6 language mode — full data-race checking is an error,
        // not a warning, for the archive engine.
        // GAP-RAR (owner 2026-11-07): libarchive 3.8.11's RAR 1.5–4.x and
        // RAR 5.0 readers, vendored verbatim (BSD-2-Clause; COPYING and
        // VENDORED.md in the target folder), behind a small C surface
        // (include/mailin_rar.h). Only libSystem is used — no zlib, bzip2,
        // lzma, iconv, OpenSSL or libxml2 (libarchive/config.h).
        .target(name: "CLibArchiveRAR",
                path: "Sources/CLibArchiveRAR",
                exclude: ["COPYING", "VENDORED.md", "VENDORED-SHA256SUMS", "patches"],
                sources: ["mailin_rar.c", "libarchive"],
                publicHeadersPath: "include",
                // Upstream code kept verbatim: its 64→32-bit shortening
                // warnings (-Wshorten-64-to-32, on by default for Apple
                // targets) are silenced for this target only.
                cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("libarchive"), .unsafeFlags(["-w"])]),
        .target(name: "ArchiveCore",
                dependencies: ["CLibArchiveRAR"],
                path: "Sources/ArchiveCore",
                swiftSettings: [.unsafeFlags(["-enable-testing"]), .swiftLanguageMode(.v6)]),
        // Runs UNSANDBOXED under `swift test` (no host app), which is what the
        // fault-injection rows need: the sandboxed app cannot write to a
        // mounted disk image at all.
        .testTarget(name: "ArchiveCoreTests",
                    dependencies: ["ArchiveCore"],
                    path: "Tests/ArchiveCoreTests",
                    // Test data read by path (#filePath), not bundled.
                    exclude: ["Fixtures"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
