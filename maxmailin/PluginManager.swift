@testable import ArchiveCore
//
//  PluginManager.swift
//  mailin
//
//  Plugin lifecycle manager: discovers, loads, validates, and sandboxes plugins.
//  Plugins provide custom analysis, export formats, and expert definitions.
//

import Foundation
import os

private let pluginTimeoutLog = Logger(subsystem: "com.ecosanskriti.maxmailin", category: "Plugins")

@MainActor
class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published private(set) var loadedPlugins: [PluginEntry] = []
    @Published private(set) var pluginFindings: [String: [MailinPluginFinding]] = [:]
    /// The deadline one plugin call gets (§8 #7); tests shorten it.
    var sandboxTimeout: Duration = .seconds(30)
    /// Plugins that overran their deadline (review 2026-11-16 E): cancelled,
    /// switched off, and stated on their card. In-process plugin code cannot be
    /// killed — cancellation is cooperative — so a plugin that ignores it is
    /// never started again while its abandoned call may still be running.
    @Published private(set) var stoppedForTimeLimit: Set<String> = []
    /// Calls still running, including ones abandoned at the deadline.
    private var running: Set<String> = []

    struct PluginEntry: Identifiable {
        let id: String
        let plugin: MailinPlugin
        var isEnabled: Bool
        var lastRunDate: Date?
        var findingsCount: Int

        var name: String { plugin.pluginName }
        var version: String { plugin.pluginVersion }
        var description: String { plugin.pluginDescription }
    }

    // MARK: - Plugin Registration

    func register(plugin: MailinPlugin) {
        guard !loadedPlugins.contains(where: { $0.id == plugin.pluginID }) else { return }
        guard validatePlugin(plugin) else { return }

        let entry = PluginEntry(
            id: plugin.pluginID,
            plugin: plugin,
            // §3-A16: a plugin the previous launch stopped inside starts off.
            isEnabled: !PluginRunnerV2.trippedAtLaunch.contains(plugin.pluginID),
            lastRunDate: nil,
            findingsCount: 0
        )
        loadedPlugins.append(entry)
    }

    func unregister(pluginID: String) {
        loadedPlugins.removeAll { $0.id == pluginID }
        pluginFindings.removeValue(forKey: pluginID)
    }

    func setEnabled(_ enabled: Bool, pluginID: String) {
        if let idx = loadedPlugins.firstIndex(where: { $0.id == pluginID }) {
            loadedPlugins[idx].isEnabled = enabled
        }
        if enabled { stoppedForTimeLimit.remove(pluginID) }
    }

    /// True while a call of this plugin (finished or abandoned) has not returned.
    func isStillRunning(_ pluginID: String) -> Bool { running.contains(pluginID) }

    // MARK: - Validation

    private func validatePlugin(_ plugin: MailinPlugin) -> Bool {
        guard !plugin.pluginID.isEmpty else { return false }
        guard !plugin.pluginName.isEmpty else { return false }
        guard plugin.pluginID.count <= 128 else { return false }
        guard plugin.pluginName.count <= 64 else { return false }
        return true
    }

    // MARK: - Run Analysis

    func runAllPlugins(emails: [MBOXParser.RawEmail]) async {
        let pluginEmails = emails.map { MailinPluginEmail(from: $0) }
        let enabledPlugins = loadedPlugins.filter(\.isEnabled)

        for entry in enabledPlugins {
            let findings = await runPluginSandboxed(entry.plugin, emails: pluginEmails)
            pluginFindings[entry.id] = findings

            if let idx = loadedPlugins.firstIndex(where: { $0.id == entry.id }) {
                loadedPlugins[idx].lastRunDate = Date()
                loadedPlugins[idx].findingsCount = findings.count
            }
        }
    }

    func runPlugin(id: String, emails: [MBOXParser.RawEmail]) async -> [MailinPluginFinding] {
        guard let entry = loadedPlugins.first(where: { $0.id == id && $0.isEnabled }) else { return [] }
        let pluginEmails = emails.map { MailinPluginEmail(from: $0) }
        let findings = await runPluginSandboxed(entry.plugin, emails: pluginEmails)
        pluginFindings[id] = findings

        if let idx = loadedPlugins.firstIndex(where: { $0.id == id }) {
            loadedPlugins[idx].lastRunDate = Date()
            loadedPlugins[idx].findingsCount = findings.count
        }
        return findings
    }

    /// Runs a plugin with a 30 s deadline that is honoured (§8 #7): the
    /// previous version raced the plugin against a sleep inside a task group,
    /// but a group waits for every child, so a plugin that never returned
    /// kept the call waiting forever. Now the first of {plugin, deadline}
    /// resumes the call; a stuck plugin is abandoned, not awaited. Findings
    /// are no longer cut at 100 without a word (rule 6).
    ///
    /// At the deadline the call is cancelled (a plugin that checks cancellation
    /// stops there) and the plugin is switched off and marked
    /// `stoppedForTimeLimit`; it is not started again while that call has not
    /// returned (review 2026-11-16 E: the deadline used to abandon the plugin
    /// and leave it on, so the next run started a second copy beside it).
    private func runPluginSandboxed(_ plugin: MailinPlugin, emails: [MailinPluginEmail]) async -> [MailinPluginFinding] {
        let id = plugin.pluginID
        guard !running.contains(id) else {
            pluginTimeoutLog.warning("plugin \(id, privacy: .public) is still running an earlier call; not started again")
            return []
        }
        running.insert(id)
        let timeout = sandboxTimeout
        let box = UncheckedPluginBox(plugin)
        let (findings, timedOut) = await withCheckedContinuation { (continuation: CheckedContinuation<([MailinPluginFinding], Bool), Never>) in
            let gate = PluginResumeGate()
            let work = Task {
                let findings = await box.plugin.analyze(emails: emails)
                await MainActor.run { _ = self.running.remove(id) }
                if gate.claim() { continuation.resume(returning: (findings, false)) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() {
                    work.cancel()
                    pluginTimeoutLog.warning("plugin \(id, privacy: .public) exceeded its time limit: cancelled and switched off")
                    continuation.resume(returning: ([], true))
                }
            }
        }
        if timedOut {
            setEnabled(false, pluginID: id)
            stoppedForTimeLimit.insert(id)
        }
        return findings
    }

    /// §3-A16: store a whole-archive run's findings (v2 runner).
    func recordWholeArchiveRun(pluginID: String, findings: [MailinPluginFinding]) {
        pluginFindings[pluginID] = findings
        if let idx = loadedPlugins.firstIndex(where: { $0.id == pluginID }) {
            loadedPlugins[idx].lastRunDate = Date()
            loadedPlugins[idx].findingsCount = findings.count
        }
    }

    // MARK: - Export

    func availableExportFormats() -> [(pluginID: String, format: MailinPluginExportFormat)] {
        var formats: [(pluginID: String, format: MailinPluginExportFormat)] = []
        for entry in loadedPlugins where entry.isEnabled {
            for format in entry.plugin.supportedExportFormats {
                formats.append((pluginID: entry.id, format: format))
            }
        }
        return formats
    }

    func export(pluginID: String, formatID: String, emails: [MBOXParser.RawEmail]) async -> Data? {
        guard let entry = loadedPlugins.first(where: { $0.id == pluginID && $0.isEnabled }) else { return nil }
        let pluginEmails = emails.map { MailinPluginEmail(from: $0) }
        return await entry.plugin.export(emails: pluginEmails, format: formatID)
    }

    // MARK: - Expert Definitions

    func allPluginExpertDefinitions() -> [(pluginID: String, expert: MailinPluginExpertDefinition)] {
        var experts: [(pluginID: String, expert: MailinPluginExpertDefinition)] = []
        for entry in loadedPlugins where entry.isEnabled {
            for expert in entry.plugin.customExpertDefinitions {
                experts.append((pluginID: entry.id, expert: expert))
            }
        }
        return experts
    }

    // MARK: - Findings for AI Integration

    func allFindingsForAI() -> String {
        var text = ""
        for (pluginID, findings) in pluginFindings {
            guard let entry = loadedPlugins.first(where: { $0.id == pluginID }) else { continue }
            let critical = findings.filter { $0.severity == .critical }
            let warnings = findings.filter { $0.severity == .warning }
            let relevant = critical + warnings
            guard !relevant.isEmpty else { continue }

            text += "PLUGIN [\(entry.name)]:\n"
            for finding in relevant.prefix(5) {
                text += "  [\(finding.severity.rawValue.uppercased())] \(finding.title): \(finding.detail)\n"
            }
            text += "\n"
        }
        return text
    }
}

/// Lets exactly one of the plugin and its deadline resume the call.
private final class PluginResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private struct UncheckedPluginBox: @unchecked Sendable {
    let plugin: MailinPlugin
    init(_ plugin: MailinPlugin) { self.plugin = plugin }
}
