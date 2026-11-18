@testable import ArchiveCore
import MailConnectivity
//
//  UITestMailSample.swift
//  maxmailin
//
//  Debug builds only. A Live Mail page with mail in it for the accessibility
//  UI audit (AccessibilityAuditUITests.testAccessibilityAudit_liveMailPage):
//  one sample account, its folders and a few captured messages, held in
//  memory. Nothing connects, nothing is written to the archive. Used only
//  on a UI-test launch (`--uitest`) of a fresh, isolated archive
//  (MAILIN_UITEST_FRESH_ARCHIVE) with MAILIN_UITEST_MAIL_SAMPLE=1.
//

import Foundation

#if DEBUG
@MainActor
enum UITestMailSample {
    nonisolated static let environmentKey = "MAILIN_UITEST_MAIL_SAMPLE"

    /// Whether this launch asked for the sample page.
    nonisolated static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments,
                                        environment: [String: String] = ProcessInfo.processInfo.environment,
                                        isolatedArchive: Bool = UITestStorageRoot.override != nil) -> Bool {
        UITestLaunch.isHonoured(arguments: arguments) && isolatedArchive && environment[environmentKey] == "1"
    }

    private static var cached: UITestMailSampleBackend?

    /// The sample backend (one per process), or nil on any other launch.
    static var backend: UITestMailSampleBackend? {
        guard isRequested() else { return nil }
        if let cached { return cached }
        let made = UITestMailSampleBackend()
        cached = made
        return made
    }
}

@MainActor
final class UITestMailSampleBackend: MailWorkspaceBackend {
    let availability: MailWorkspaceAvailability = .ready
    private let account = MailAccount(provider: .imap, host: "imap.example.org", port: 993,
                                      loginName: "asha@example.org", displayIdentity: "asha@example.org",
                                      enabledModes: [.capture], connectionState: .connected)
    private var rows: [ConnectedMailboxRow] = []
    private var raw: [UUID: String] = [:]

    init() {
        let samples: [(from: String, subject: String, preview: String, read: Bool, flagged: Bool, attachment: Bool, folder: String)] = [
            ("Dana Kim <dana.kim@example.com>", "Revised supplier contract", "Please find the revised contract attached.", false, true, true, "INBOX"),
            ("Ravi Menon <ravi@example.net>", "Q3 invoice", "The invoice for the third quarter is ready.", true, false, false, "INBOX"),
            ("Lee Chen <lee.chen@example.com>", "Board minutes", "Minutes of Tuesday's meeting.", true, false, false, "Projects"),
        ]
        for (i, s) in samples.enumerated() {
            let id = UUID()
            let date = Date(timeIntervalSince1970: 1_762_000_000 - Double(i) * 86_400)
            rows.append(ConnectedMailboxRow(emailID: id, accountID: account.id,
                                            identity: .imap(mailbox: s.folder, uidValidity: 1, uid: UInt32(i + 1)),
                                            subject: s.subject, from: s.from, date: date, hasAttachments: s.attachment,
                                            isRead: s.read, isFlagged: s.flagged, onServer: true,
                                            folderServerIDs: [s.folder], identityKey: "sample-\(i)",
                                            preview: s.preview, to: "asha@example.org"))
            raw[id] = "Message-ID: <ui-sample-\(i)@example.org>\nSubject: \(s.subject)\nFrom: \(s.from)\n"
                + "To: asha@example.org\nDate: \(date.formatted(.iso8601))\n\n\(s.preview)\n"
        }
    }

    func accounts() async throws -> [MailAccountSnapshot] {
        [MailAccountSnapshot(account: account, status: nil, unavailableReason: nil, isPaused: false, lastRunSummary: nil)]
    }

    func folders(_ id: UUID) async throws -> [ConnectedFolderSummary] {
        guard id == account.id else { return [] }
        return [("INBOX", "INBOX", "\\Inbox"), ("Projects", "Projects", nil)].map { serverID, path, special in
            let inFolder = rows.filter { $0.folderServerIDs.contains(serverID) }
            return ConnectedFolderSummary(accountID: account.id, serverID: serverID, path: path, kind: .folder, specialUse: special,
                                          messages: inFolder.count, unread: inFolder.filter { $0.isRead == false }.count,
                                          selected: true)
        }
    }

    func mailbox(_ query: ConnectedMailboxQuery, after: ConnectedMailboxCursor?) async throws -> ConnectedMailboxPage {
        let listed = rows.filter { row in
            (query.folderServerID.map { row.folderServerIDs.contains($0) } ?? true)
                && (!query.unreadOnly || row.isRead == false)
                && (!query.flaggedOnly || row.isFlagged == true)
                && (!query.attachmentsOnly || row.hasAttachments)
                && (query.text.isEmpty || "\(row.from) \(row.subject) \(row.preview)".localizedCaseInsensitiveContains(query.text))
        }
        return ConnectedMailboxPage(rows: listed, total: listed.count, next: nil)
    }

    func email(_ id: UUID) async throws -> MBOXParser.RawEmail? {
        guard let text = raw[id] else { return nil }
        return try MBOXParser.processRawMessage(text, senderEmail: "", materializeAttachments: false)
    }
}
#endif
