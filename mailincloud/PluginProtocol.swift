//
//  PluginProtocol.swift
//  mailin
//
//  Plugin API for extending mailin with custom analysis, export formats, and experts.
//

import Foundation

// MARK: - Plugin Protocol

protocol MailinPlugin: AnyObject {
    var pluginID: String { get }
    var pluginName: String { get }
    var pluginVersion: String { get }
    var pluginDescription: String { get }

    func analyze(emails: [MailinPluginEmail]) async -> [MailinPluginFinding]

    var supportedExportFormats: [MailinPluginExportFormat] { get }
    func export(emails: [MailinPluginEmail], format: String) async -> Data?

    var customExpertDefinitions: [MailinPluginExpertDefinition] { get }
}

extension MailinPlugin {
    var supportedExportFormats: [MailinPluginExportFormat] { [] }
    func export(emails: [MailinPluginEmail], format: String) async -> Data? { nil }
    var customExpertDefinitions: [MailinPluginExpertDefinition] { [] }
}

// MARK: - Plugin Data Types (Sandboxed — no access to internal types)

struct MailinPluginEmail: Sendable {
    let id: UUID
    let subject: String
    let from: String
    let to: String
    let date: String
    let body: String
    let headers: [String: String]
    let attachmentNames: [String]
    let tags: [String]

    init(from email: MBOXParser.RawEmail) {
        self.id = email.id
        self.subject = email.headers["Subject"] ?? ""
        self.from = email.headers["From"] ?? ""
        self.to = email.headers["To"] ?? ""
        self.date = email.headers["Date"] ?? ""
        self.body = String(email.plainBody.prefix(5000))
        self.headers = email.headers
        self.attachmentNames = email.attachments.map(\.filename)
        self.tags = email.tags
    }
}

struct MailinPluginFinding: Sendable {
    let title: String
    let detail: String
    let severity: Severity
    let relatedEmailIDs: [UUID]

    enum Severity: String, Sendable {
        case info
        case warning
        case critical
    }
}

struct MailinPluginExportFormat: Sendable {
    let formatID: String
    let displayName: String
    let fileExtension: String
}

struct MailinPluginExpertDefinition: Sendable {
    let name: String
    let instructions: String
    let keywords: [String]
}
