//
//  BatesNumberingManager.swift
//  mailin
//
//  Bates numbering system for legal discovery.
//  Assigns sequential, zero-padded identifiers to emails for litigation support.
//

import SwiftUI
import os.log

private let batesLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "BatesNumbering")

// MARK: - BatesNumberingManager

@MainActor
class BatesNumberingManager: ObservableObject {
    static let shared = BatesNumberingManager()

    @Published var prefix: String = "MAILIN" {
        didSet { if _initialized { persistAssignments() } }
    }
    @Published var startNumber: Int = 1 {
        didSet { if _initialized { persistAssignments() } }
    }
    @Published var zeroPadding: Int = 6 {
        didSet { if _initialized { persistAssignments() } }
    }
    @Published var assignments: [UUID: String] = [:]

    private var _initialized = false
    private static let assignmentsKey = "batesNumberAssignments"
    private static let configKey = "batesNumberConfig"

    init() {
        loadAssignments()
        loadConfig()
        _initialized = true
    }

    // MARK: - Formatting

    func formatNumber(_ n: Int) -> String {
        let safePadding = max(1, zeroPadding)
        return "\(prefix)\(String(format: "%0\(safePadding)d", n))"
    }

    // MARK: - Assignment

    /// Assigns sequential Bates numbers to emails sorted by date.
    /// Returns the mapping of email ID to Bates number.
    @discardableResult
    func assignNumbers(to emails: [MBOXParser.RawEmail]) -> [UUID: String] {
        let sorted = emails.sorted { email1, email2 in
            let date1 = MBOXParser.parseDate(email1.headers["Date"])
            let date2 = MBOXParser.parseDate(email2.headers["Date"])
            switch (date1, date2) {
            case let (d1?, d2?): return d1 < d2
            case (nil, _): return true
            case (_, nil): return false
            }
        }

        var newAssignments: [UUID: String] = [:]
        for (index, email) in sorted.enumerated() {
            let batesNumber = formatNumber(startNumber + index)
            newAssignments[email.id] = batesNumber
        }

        assignments = newAssignments
        persistAssignments()

        ForensicManager.shared.logAction(
            "Bates Numbers Assigned",
            detail: "Assigned \(newAssignments.count) Bates numbers (\(formatNumber(startNumber)) through \(formatNumber(startNumber + max(sorted.count - 1, 0))))"
        )

        batesLog.info("Assigned \(newAssignments.count) Bates numbers with prefix \(self.prefix)")
        return newAssignments
    }

    func getBatesNumber(for emailID: UUID) -> String? {
        assignments[emailID]
    }

    /// Removes all Bates number assignments. This is typically irreversible
    /// in legal proceedings — use with caution.
    func removeAllNumbers() {
        let count = assignments.count
        assignments.removeAll()
        persistAssignments()

        ForensicManager.shared.logAction(
            "Bates Numbers Removed",
            detail: "Removed \(count) Bates number assignment(s)"
        )

        batesLog.warning("All \(count) Bates number assignments removed")
    }

    // MARK: - Export

    /// Exports a CSV index of all Bates-numbered emails.
    func exportBatesIndex(emails: [MBOXParser.RawEmail]) -> Data {
        var csv = "BatesNumber,From,To,Subject,Date,MessageID,AttachmentCount\n"

        func csvEscape(_ s: String) -> String {
            var v = s
            if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "") + "\""
        }

        let sorted = emails.sorted { email1, email2 in
            let b1 = assignments[email1.id] ?? ""
            let b2 = assignments[email2.id] ?? ""
            return b1 < b2
        }

        for email in sorted {
            guard let batesNumber = assignments[email.id] else { continue }
            let from = email.headers["From"] ?? ""
            let to = email.headers["To"] ?? ""
            let subject = email.headers["Subject"] ?? ""
            let date = email.headers["Date"] ?? ""
            let messageID = email.headers["Message-ID"] ?? email.headers["Message-Id"] ?? ""
            let attachmentCount = email.attachments.count

            csv += "\(csvEscape(batesNumber)),"
            csv += "\(csvEscape(from)),"
            csv += "\(csvEscape(to)),"
            csv += "\(csvEscape(subject)),"
            csv += "\(csvEscape(date)),"
            csv += "\(csvEscape(messageID)),"
            csv += "\(attachmentCount)\n"
        }

        ForensicManager.shared.logAction(
            "Bates Index Exported",
            detail: "Exported CSV index with \(assignments.count) entries"
        )

        return csv.data(using: .utf8) ?? Data()
    }

    // MARK: - Persistence

    private func persistAssignments() {
        let stringDict = assignments.reduce(into: [String: String]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        if let data = try? JSONEncoder().encode(stringDict) {
            UserDefaults.standard.set(data, forKey: Self.assignmentsKey)
        }
        let config: [String: Any] = [
            "prefix": prefix,
            "startNumber": startNumber,
            "zeroPadding": zeroPadding
        ]
        UserDefaults.standard.set(config, forKey: Self.configKey)
    }

    private func loadAssignments() {
        guard let data = UserDefaults.standard.data(forKey: Self.assignmentsKey),
              let stringDict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (key, value) in stringDict {
            if let uuid = UUID(uuidString: key) {
                assignments[uuid] = value
            }
        }
    }

    private func loadConfig() {
        guard let config = UserDefaults.standard.dictionary(forKey: Self.configKey) else { return }
        if let p = config["prefix"] as? String { prefix = p }
        if let s = config["startNumber"] as? Int { startNumber = s }
        if let z = config["zeroPadding"] as? Int { zeroPadding = z }
    }
}

// MARK: - BatesConfigView

struct BatesConfigView: View {
    let emails: [MBOXParser.RawEmail]

    @StateObject private var manager = BatesNumberingManager()
    @State private var assignmentComplete = false
    @State private var exportMessage: String?
    @State private var showExportMessage = false
    @State private var showTutorial = false
    @State private var showRemoveConfirmation = false
    #if os(iOS)
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            // Header
            HStack {
                Label("Bates Numbering", systemImage: "number.square")
                    .font(Typography.title3)
                    .foregroundColor(AppColors.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                TutorialHelpButton(showTutorial: $showTutorial)
            }

            Text("Assign sequential Bates numbers to emails for legal discovery and document production.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            Divider()
                .background(AppColors.separatorLight)

            // Configuration
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("Configuration")
                    .font(Typography.headline)

                HStack(spacing: Spacing.medium) {
                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text("Prefix")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        TextField("Prefix", text: $manager.prefix)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Bates number prefix")
                            #if os(macOS)
                            .frame(width: 120)
                            #endif
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text("Start Number")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        TextField("Start", value: $manager.startNumber, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Starting number")
                            #if os(macOS)
                            .frame(width: 80)
                            #endif
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text("Zero Padding")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        TextField("Padding", value: $manager.zeroPadding, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Number of digits for zero padding")
                            #if os(macOS)
                            .frame(width: 60)
                            #endif
                    }
                }
            }
            .padding(Spacing.small)
            .background(AppColors.backgroundSecondary)
            .cornerRadius(CornerRadius.medium)

            // Preview
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text("Preview")
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)

                HStack(spacing: Spacing.large) {
                    HStack(spacing: Spacing.xSmall) {
                        Text("First:")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        Text(manager.formatNumber(manager.startNumber))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(AppColors.primary)
                    }

                    HStack(spacing: Spacing.xSmall) {
                        Text("Last:")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        Text(manager.formatNumber(manager.startNumber + max(emails.count - 1, 0)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(AppColors.primary)
                    }

                    Spacer()

                    Text("\(emails.count) emails")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
            .padding(Spacing.small)
            .background(AppColors.backgroundTertiary)
            .cornerRadius(CornerRadius.small)

            // Actions
            HStack(spacing: Spacing.small) {
                Button {
                    manager.assignNumbers(to: emails)
                    assignmentComplete = true
                } label: {
                    Label("Assign Bates Numbers", systemImage: "number.square.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Assigns sequential Bates numbers to all \(emails.count) emails sorted by date")

                Button {
                    let data = manager.exportBatesIndex(emails: emails)
                    saveBatesIndex(data: data)
                } label: {
                    Label("Export Bates Index", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(manager.assignments.isEmpty)
                .accessibilityHint("Exports a CSV file mapping Bates numbers to email metadata")

                Button {
                    showRemoveConfirmation = true
                } label: {
                    Label("Remove Bates Numbers", systemImage: "trash")
                        .foregroundColor(AppColors.error)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(manager.assignments.isEmpty)
                .accessibilityLabel("Remove all Bates numbers")
                .accessibilityHint("Shows a warning before permanently removing all Bates number assignments")
            }

            // Status
            if assignmentComplete {
                Label(
                    "Assigned \(manager.assignments.count) Bates numbers successfully.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(Typography.callout)
                .foregroundColor(AppColors.success)
                .accessibilityLabel("Assignment complete. \(manager.assignments.count) Bates numbers assigned.")

                Label {
                    Text("Bates numbers provide unique sequential identifiers for each document in legal proceedings. These numbers are permanent — once assigned, they create a fixed reference for production and court citation.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "number.circle.fill")
                        .foregroundColor(.blue)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(CornerRadius.small)
            }

            if let message = exportMessage, showExportMessage {
                Label(message, systemImage: "doc.text")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.info)
            }
        }
        .padding(Spacing.medium)
        .featureTutorial(.batesNumbering, key: "bates_numbering_tutorial_seen", isPresented: $showTutorial)
        .adaptiveDestructiveConfirmation(
            "Remove Bates Numbers",
            isPresented: $showRemoveConfirmation,
            message: "This will permanently remove all Bates number assignments. In legal proceedings, Bates numbers are typically permanent once assigned. This action is logged in the forensic audit trail and cannot be undone.",
            actionTitle: "Remove All"
        ) {
            manager.removeAllNumbers()
            assignmentComplete = false
        }
        .adaptiveCard(cornerRadius: CornerRadius.large)
        #if os(macOS)
        .frame(minWidth: 400, maxWidth: 600)
        #else
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
    }

    // MARK: - File Save

    private func saveBatesIndex(data: Data) {
        #if os(macOS)
        if PlatformFileSaver.saveData(data, suggestedName: "BatesIndex_\(manager.prefix).csv") {
            exportMessage = "Bates index exported successfully."
        } else {
            exportMessage = "Export cancelled."
        }
        showExportMessage = true
        #else
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatesIndex_\(manager.prefix).csv")
        do {
            try data.write(to: url, options: .atomic)
            shareItems = [url]
            showShareSheet = true
        } catch {
            exportMessage = "Failed to save Bates index."
            showExportMessage = true
        }
        #endif
    }
}
