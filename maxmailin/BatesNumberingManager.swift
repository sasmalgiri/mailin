@testable import ArchiveCore
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

    /// Where numbers and settings are kept (tests pass a disposable suite).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    /// The next number that can be used: above every number already
    /// assigned with the current prefix, never below the configured start.
    func nextFreeNumber() -> Int {
        let used = assignments.values.compactMap { number -> Int? in
            guard number.hasPrefix(prefix) else { return nil }
            return Int(number.dropFirst(prefix.count))
        }.max() ?? 0
        return max(startNumber, used + 1)
    }

    /// How many of `emails` have no number yet (the ones a run would number).
    func unnumberedCount(in emails: [MBOXParser.RawEmail]) -> Int {
        emails.reduce(0) { $0 + (assignments[$1.id] == nil ? 1 : 0) }
    }

    /// Assigns Bates numbers, in date order, to the emails that have none.
    /// Rule 3: a number once assigned is never changed or reused — emails
    /// that already have one keep it, and the sequence continues after the
    /// highest number used. (Before 3.0 every call replaced all assignments
    /// with a fresh sequence over the given emails.)
    /// Returns the numbers assigned by this call.
    @discardableResult
    func assignNumbers(to emails: [MBOXParser.RawEmail]) -> [UUID: String] {
        guard OrgPolicy.allows(.produce) else { return [:] }   // enterprise role (OrgPolicy)
        let sorted = emails.filter { assignments[$0.id] == nil }.sorted { email1, email2 in
            let date1 = MBOXParser.parseDate(email1.headers["Date"])
            let date2 = MBOXParser.parseDate(email2.headers["Date"])
            switch (date1, date2) {
            case let (d1?, d2?): return d1 < d2
            case (nil, _): return true
            case (_, nil): return false
            }
        }
        let alreadyNumbered = emails.count - sorted.count
        let first = nextFreeNumber()

        var newAssignments: [UUID: String] = [:]
        for (index, email) in sorted.enumerated() {
            newAssignments[email.id] = formatNumber(first + index)
        }

        for (id, number) in newAssignments { assignments[id] = number }
        startNumber = max(startNumber, first + sorted.count)
        persistAssignments()

        let range = sorted.isEmpty ? "none" : "\(formatNumber(first)) through \(formatNumber(first + sorted.count - 1))"
        ScopeJobEnvironment.logAction(
            "Bates Numbers Assigned",
            detail: "Assigned \(newAssignments.count) new Bates numbers (\(range)); \(alreadyNumbered) already numbered, unchanged"
        )

        batesLog.info("Assigned \(newAssignments.count) Bates numbers with prefix \(self.prefix); \(alreadyNumbered) unchanged")
        return newAssignments
    }

    func getBatesNumber(for emailID: UUID) -> String? {
        assignments[emailID]
    }

    /// F-4: a production run's numbers join the record and the sequence
    /// continues after them, so two productions never reuse a number.
    /// `log: false` when the caller writes the audit entry itself (the 3.0
    /// engine), so one action is one entry.
    func merge(assignments new: [UUID: String], nextStart: Int, log: Bool = true) {
        for (id, number) in new { assignments[id] = number }
        startNumber = max(startNumber, nextStart)
        persistAssignments()
        guard log else { return }
        ScopeJobEnvironment.logAction(
            "Bates Numbers Assigned",
            detail: "Production assigned \(new.count) Bates numbers; sequence continues at \(formatNumber(startNumber))")
    }

    /// Removes all Bates number assignments. This is typically irreversible
    /// in legal proceedings — use with caution.
    func removeAllNumbers() {
        let count = assignments.count
        assignments.removeAll()
        persistAssignments()

        ScopeJobEnvironment.logAction(
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

        ScopeJobEnvironment.logAction(
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
            defaults.set(data, forKey: Self.assignmentsKey)
        }
        let config: [String: Any] = [
            "prefix": prefix,
            "startNumber": startNumber,
            "zeroPadding": zeroPadding
        ]
        defaults.set(config, forKey: Self.configKey)
    }

    private func loadAssignments() {
        guard let data = defaults.data(forKey: Self.assignmentsKey),
              let stringDict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (key, value) in stringDict {
            if let uuid = UUID(uuidString: key) {
                assignments[uuid] = value
            }
        }
    }

    private func loadConfig() {
        guard let config = defaults.dictionary(forKey: Self.configKey) else { return }
        if let p = config["prefix"] as? String { prefix = p }
        if let s = config["startNumber"] as? Int { startNumber = s }
        if let z = config["zeroPadding"] as? Int { zeroPadding = z }
    }
}

// MARK: - BatesConfigView

struct BatesConfigView: View {
    let emails: [MBOXParser.RawEmail]

    @StateObject private var manager = BatesNumberingManager()
    // §3-L6: whole-scope numbering that never renumbers.
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    @Environment(\.archiveScope) private var scope
    @State private var scopeConfirm: ScopeConfirmationRequest?
    @State private var v3Total: Int?
    @State private var v3Busy = false
    @State private var v3Status: String?
    private var v3: Bool { modules?.isOn(.v3Bates) ?? false }
    /// Emails a run would number: the whole scope (3.0) or the unnumbered
    /// loaded emails — already-numbered ones are never renumbered.
    private var previewCount: Int { v3 ? (v3Total ?? emails.count) : manager.unnumberedCount(in: emails) }
    @State private var assignmentComplete = false
    /// Numbers assigned by the last run (not the running total).
    @State private var lastAssigned = 0
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
                        Text(manager.formatNumber(manager.nextFreeNumber()))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(AppColors.primary)
                    }

                    HStack(spacing: Spacing.xSmall) {
                        Text("Last:")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        Text(manager.formatNumber(manager.nextFreeNumber() + max(previewCount - 1, 0)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(AppColors.primary)
                    }

                    Spacer()

                    Text("\(previewCount) emails")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
            .padding(Spacing.small)
            .background(AppColors.backgroundTertiary)
            .cornerRadius(CornerRadius.small)

            if v3 {
                WholeScopeNote()
                Text("Numbers already assigned are never changed; new numbers continue after the highest one used.")
                    .font(Typography.caption1).foregroundColor(AppColors.secondary)
            }

            // Actions
            HStack(spacing: Spacing.small) {
                Button {
                    if v3 { confirmV3Assign(); return }
                    let n = manager.assignNumbers(to: emails).count
                    lastAssigned = n
                    assignmentComplete = true
                    // Record a numbered document of this Bates run.
                    Task { await DocumentRegistry.captureStructured(.report,
                        summary: "Bates numbering — \(n) emails",
                        document: CapturedDocument(title: "Bates Numbering", sections: [
                          .init(name: "Bates Numbering", fields: [.init(key: "Emails", value: "\(n)")])])) }
                } label: {
                    Label("Assign Bates Numbers", systemImage: "number.square.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Assigns Bates numbers, in date order, to the \(previewCount) emails that do not have one yet")

                Button {
                    if v3 {
                        v3Busy = true
                        Task { @MainActor in
                            defer { v3Busy = false }
                            let (outcome, n) = await BatesEngine.exportIndex(scope: scope, manager: manager)
                            exportMessage = outcome.message(String(localized: "Bates index")) + (outcome.succeeded ? " (\(n))" : "")
                            showExportMessage = true
                        }
                        return
                    }
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
                    "Assigned \(lastAssigned) new Bates numbers.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(Typography.callout)
                .foregroundColor(AppColors.success)
                .accessibilityLabel("Assignment complete. \(lastAssigned) new Bates numbers assigned.")

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

            if v3Busy { ProgressView().controlSize(.small) }
            if let v3Status {
                Label(v3Status, systemImage: "checkmark.circle.fill")
                    .font(Typography.callout).foregroundColor(AppColors.success)
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
            if v3 {
                // The database copy is removed too, or the numbers would
                // return on the next merge.
                Task { @MainActor in
                    let store = SQLiteEmailStore.shared
                    if let all = try? await store.reviewCoding(workspace: BatesEngine.workspace, field: BatesEngine.field) {
                        try? await store.reviewCodingSet(workspace: BatesEngine.workspace, field: BatesEngine.field,
                                                         values: all.mapValues { _ in nil })
                    }
                    v3Status = nil
                }
            }
        }
        .scopeConfirmation($scopeConfirm)
        .task(id: v3) { if v3 { v3Total = await scope.resolvedTotal() } }
        .adaptiveCard(cornerRadius: CornerRadius.large)
        #if os(macOS)
        .frame(minWidth: 400, maxWidth: 600)
        #else
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
    }

    // MARK: - 3.0 whole-scope assignment

    private func confirmV3Assign() {
        Task { @MainActor in
            scopeConfirm = await ScopeConfirm.request(
                scope, title: String(localized: "Assign Bates Numbers"), verb: String(localized: "Assign"),
                detail: String(localized: "Emails that already have a number keep it.")
            ) {
                v3Busy = true
                defer { v3Busy = false }
                do {
                    let r = try await BatesEngine.assign(scope: scope, manager: manager)
                    lastAssigned = r.state.assigned
                    assignmentComplete = true
                    v3Status = String(localized: "Assigned \(r.state.assigned) new Bates numbers (\(r.state.first ?? "—")–\(r.state.last ?? "—")); \(r.state.skipped) already numbered, unchanged.")
                    await DocumentRegistry.captureStructured(.report,
                        summary: "Bates numbering — \(r.state.assigned) new, \(r.state.skipped) unchanged",
                        document: CapturedDocument(title: "Bates Numbering", sections: [
                            .init(name: "Bates Numbering", fields: [
                                .init(key: "New numbers", value: "\(r.state.assigned)"),
                                .init(key: "First", value: r.state.first ?? "—"),
                                .init(key: "Last", value: r.state.last ?? "—"),
                                .init(key: "Already numbered (unchanged)", value: "\(r.state.skipped)")]),
                            .init(name: String(localized: "Job receipt"), fields: r.receipt.documentFields)]))
                } catch is CancellationError {
                    v3Status = nil
                } catch {
                    // §3-M3: the previous engine numbers the loaded emails
                    // (it never renumbers either, finding #4).
                    v3Status = EngineGuard.fellBack(.v3Bates, error: error)
                    lastAssigned = manager.assignNumbers(to: emails).count
                    assignmentComplete = true
                }
            }
        }
    }

    // MARK: - File Save

    private func saveBatesIndex(data: Data) {
        #if os(macOS)
        // Distinguish a cancelled panel from a failed write.
        exportMessage = PlatformExport.save(data: data, suggestedName: "BatesIndex_\(manager.prefix).csv")
            .message(String(localized: "Bates index"))
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
