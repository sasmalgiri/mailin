// swift-tools-version: 6.0
// §3-P3 coverage-guided fuzzing harness for ArchiveCore's parsers.
//
// Builds ONLY with a toolchain that ships libFuzzer (`-sanitize=fuzzer`), e.g.
// the swift.org toolchain for macOS. Apple's Xcode toolchain rejects that flag
// on macOS, which is why this is a separate package and not part of the app or
// the test suite. Run with `Scripts/fuzz.sh` (see Fuzz/README.md).
import PackageDescription

let package = Package(
    name: "ArchiveCoreFuzz",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Packages/ArchiveCore")],
    targets: [
        .executableTarget(
            name: "ArchiveCoreFuzz",
            dependencies: [.product(name: "ArchiveCore", package: "ArchiveCore")],
            path: "Sources/ArchiveCoreFuzz",
            swiftSettings: [.unsafeFlags(["-sanitize=fuzzer,address", "-parse-as-library"])],
            linkerSettings: [.unsafeFlags(["-sanitize=fuzzer,address"])]
        )
    ]
)
