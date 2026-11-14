//
//  UITestStorageRoot.swift
//  ArchiveCore
//
//  CLOSE-06: the five-journey Mac UI test needs a fresh, empty archive that
//  can never touch the person's own. When — and only when — the app is
//  launched with the `--uitest` argument AND the environment variable
//  `MAILIN_UITEST_FRESH_ARCHIVE=<token>`, every store that would live in
//  Application Support (SQLite store, search index, receipts, checkpoints,
//  module switches, recipe runs …) is rooted in a per-token folder inside the
//  app's own temporary directory instead. Without both, this returns the real
//  Application Support directory unchanged: the hook is inert in every normal
//  launch (neither is ever set by the app itself).
//

import Foundation

enum UITestStorageRoot {
    static let environmentKey = "MAILIN_UITEST_FRESH_ARCHIVE"
    static let launchArgument = "--uitest"

    /// The isolated base, or nil when the hook is not engaged.
    static let override: URL? = resolve(arguments: ProcessInfo.processInfo.arguments,
                                        environment: ProcessInfo.processInfo.environment,
                                        temporaryDirectory: FileManager.default.temporaryDirectory)

    /// Pure resolution (testable): both switches, and a token of letters,
    /// digits, "-" or "_" only, so the folder can never escape the temp dir.
    static func resolve(arguments: [String], environment: [String: String], temporaryDirectory: URL) -> URL? {
        guard arguments.contains(launchArgument),
              let token = environment[environmentKey], !token.isEmpty, token.count <= 64,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let base = temporaryDirectory
            .appendingPathComponent("mailin-uitest-\(token)", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// `<Application Support>` — or the isolated base during a fresh-archive UI test.
    static var applicationSupport: URL {
        if let override { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
