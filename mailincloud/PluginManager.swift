//
//  PluginManager.swift
//  mailin
//
//  Plugin lifecycle manager: discovers, loads, validates, and sandboxes plugins.
//  Plugins provide custom analysis, export formats, and expert definitions.
//

import Foundation

@MainActor
class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published private(set) var loadedPlugins: [PluginEntry] = []
    @Published private(set) var pluginFindings: [String: [MailinPluginFinding]] = [:]

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
            isEnabled: true,
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
    }

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

    private func runPluginSandboxed(_ plugin: MailinPlugin, emails: [MailinPluginEmail]) async -> [MailinPluginFinding] {
        let maxFindings = 100
        let timeout: UInt64 = 30_000_000_000

        return await withCheckedContinuation { continuation in
            Task {
                let result = await withTaskGroup(of: [MailinPluginFinding]?.self) { group in
                    group.addTask {
                        let findings = await plugin.analyze(emails: emails)
                        return Array(findings.prefix(maxFindings))
                    }

                    group.addTask {
                        try? await Task.sleep(nanoseconds: timeout)
                        return nil
                    }

                    for await result in group {
                        if let findings = result {
                            group.cancelAll()
                            return findings
                        }
                    }
                    return []
                }
                continuation.resume(returning: result)
            }
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
