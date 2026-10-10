@testable import ArchiveCore
//
//  PluginRunnerV2.swift
//  maxmailin
//
//  §3-A16 (switch: `v3AnalysisQueries`). Plugin API v2 over the WHOLE archive.
//
//   • A plugin is fed the archive as a stream of batches. Plugins that adopt
//     `MailinPluginV2` get begin / batch / finish calls (so they can keep
//     their own running totals); every other plugin's `analyze(emails:)` is
//     called once per batch and its findings are merged.
//   • Each call races a deadline that is honoured: a call that overruns is
//     abandoned (its result ignored) and counted; the run continues.
//   • Crash isolation: a breadcrumb per plugin run. If the app stops inside a
//     plugin, that plugin is switched off at the next launch and the user is
//     told — the same rule the 3.0 engines follow.
//

import Foundation

/// Optional streaming API for plugins (v2).
protocol MailinPluginV2: MailinPlugin {
    func beginArchiveRun(totalEmails: Int) async
    func analyze(batch: [MailinPluginEmail]) async -> [MailinPluginFinding]
    func finishArchiveRun() async -> [MailinPluginFinding]
}

@MainActor
enum PluginRunnerV2 {
    static let callTimeout: Duration = .seconds(30)

    struct Outcome {
        var findings: [MailinPluginFinding]
        var batches: Int
        var timedOut: Int
        var emails: Int
    }

    /// Runs `work` with a deadline; nil when the deadline passed first.
    nonisolated static func withDeadline<T: Sendable>(_ deadline: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: deadline); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Crash isolation

    private static var directory: URL {
        EngineGuard.directory.appendingPathComponent("plugins", isDirectory: true)
    }

    static func begin(_ pluginID: String) -> URL {
        let url = directory.appendingPathComponent(pluginID.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(pluginID.utf8).write(to: url, options: .atomic)
        return url
    }

    static func end(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// Collected once per launch, on first use.
    static let trippedAtLaunch: Set<String> = {
        let ids = Set(trippedPlugins())
        for id in ids {
            ForensicManager.shared.logAction("Plugin switched off after an unexpected stop", detail: id)
        }
        return ids
    }()

    /// Plugins the previous launch stopped inside. Call once at launch.
    static func trippedPlugins() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [String] = []
        for f in files {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard modified < EngineGuard.launchDate else { continue }
            if let id = try? String(contentsOf: f, encoding: .utf8) { out.append(id) }
            try? FileManager.default.removeItem(at: f)
        }
        return out
    }

    // MARK: Run

    static func run(_ plugin: MailinPlugin, query: EmailQuery = .all) async throws -> Outcome {
        let breadcrumb = begin(plugin.pluginID)
        defer { end(breadcrumb) }
        let data = ArchiveDataService.shared
        let total = try await data.count(query: query)
        var outcome = Outcome(findings: [], batches: 0, timedOut: 0, emails: 0)
        let v2 = plugin as? MailinPluginV2
        let unchecked = UncheckedPlugin(plugin)
        if let v2 {
            let box = UncheckedPlugin(v2)
            _ = await withDeadline(callTimeout) { await (box.plugin as? MailinPluginV2)?.beginArchiveRun(totalEmails: total) }
        }
        for try await batch in data.streamFullEmails(query: query, batchSize: 500) {
            try Task.checkCancellation()
            let pluginEmails = batch.map { MailinPluginEmail(from: $0) }
            let found = await withDeadline(callTimeout) { () -> [MailinPluginFinding] in
                if let p = unchecked.plugin as? MailinPluginV2 { return await p.analyze(batch: pluginEmails) }
                return await unchecked.plugin.analyze(emails: pluginEmails)
            }
            outcome.batches += 1
            outcome.emails += batch.count
            if let found { outcome.findings += found } else { outcome.timedOut += 1 }
        }
        if v2 != nil {
            if let final = await withDeadline(callTimeout, { await (unchecked.plugin as? MailinPluginV2)?.finishArchiveRun() ?? [] }) {
                outcome.findings += final
            } else {
                outcome.timedOut += 1
            }
        }
        return outcome
    }
}

/// Plugins are main-actor-created reference types; calls are serialised by
/// this runner, so passing the reference into the deadline task is safe.
private struct UncheckedPlugin: @unchecked Sendable {
    let plugin: MailinPlugin
    init(_ plugin: MailinPlugin) { self.plugin = plugin }
}

extension PluginManager {
    /// Whole-archive run of every enabled plugin (v2 runner).
    func runAllPluginsWholeArchive() async -> [String: PluginRunnerV2.Outcome] {
        var outcomes: [String: PluginRunnerV2.Outcome] = [:]
        for entry in loadedPlugins where entry.isEnabled {
            guard let outcome = try? await PluginRunnerV2.run(entry.plugin) else { continue }
            outcomes[entry.id] = outcome
            recordWholeArchiveRun(pluginID: entry.id, findings: outcome.findings)
        }
        return outcomes
    }

}
