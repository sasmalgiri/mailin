//
//  EngineBreadcrumbs.swift
//  ArchiveCore
//
//  Review 2026-11-16 C23 (rule 15): the crash breadcrumb for engines that run
//  inside the package. The app's EngineGuard writes a small file while an
//  engine runs and, at the next launch, switches off any engine the previous
//  process stopped inside — but the PST spec reader, the Notes ODS reader,
//  the streaming binary parsers and the store-level switches run here, where
//  EngineGuard cannot be seen. The app installs `begin` at launch
//  (ArchiveCoreBridge); without it (package tests, tools) a run is simply
//  not crash-protected.
//
//  Engine names are the app's `Capability` raw values ("v3PSTSpecReader").
//

import Foundation

public enum EngineBreadcrumbs {
    /// Starts a breadcrumb for `engine` and returns the closure that removes it.
    nonisolated(unsafe) public static var begin: (@Sendable (_ engine: String) -> (@Sendable () -> Void))?

    /// Starts `engine`'s breadcrumb for a run that spans more than one call;
    /// call the returned closure when it ends (`defer`). nil = unguarded.
    public static func start(_ engine: String?) -> @Sendable () -> Void {
        guard let engine, let begin else { return {} }
        return begin(engine)
    }

    /// Runs `body` inside `engine`'s breadcrumb; `engine` nil runs it unguarded
    /// (the engine's switch is off, so the earlier path is what runs).
    public static func run<T>(_ engine: String?, _ body: () throws -> T) rethrows -> T {
        guard let engine, let begin else { return try body() }
        let end = begin(engine)
        defer { end() }
        return try body()
    }

    /// Runs on the caller's actor (`isolation`), so the body is never sent across actors.
    public static func run<T>(_ engine: String?, isolation: isolated (any Actor)? = #isolation,
                              _ body: () async throws -> T) async rethrows -> T {
        guard let engine, let begin else { return try await body() }
        let end = begin(engine)
        defer { end() }
        return try await body()
    }
}
