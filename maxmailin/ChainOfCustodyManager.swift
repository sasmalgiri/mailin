@testable import ArchiveCore
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Chain of Custody Event

struct CustodyEvent: Codable, Identifiable {
    let id: UUID
    let date: Date
    let eventType: EventType
    let actor: String
    let description: String
    let emailIDs: [UUID]
    let hashBefore: String?
    let hashAfter: String?

    enum EventType: String, Codable, CaseIterable {
        case imported = "Imported"
        case accessed = "Accessed"
        case exported = "Exported"
        case modified = "Modified"
        case transferred = "Transferred"
        case sealed = "Sealed"

        var icon: String {
            switch self {
            case .imported: return "square.and.arrow.down"
            case .accessed: return "eye"
            case .exported: return "square.and.arrow.up"
            case .modified: return "pencil"
            case .transferred: return "arrow.right.arrow.left"
            case .sealed: return "lock.shield"
            }
        }

        var color: Color {
            switch self {
            case .imported: return .blue
            case .accessed: return .green
            case .exported: return .orange
            case .modified: return .purple
            case .transferred: return .teal
            case .sealed: return .red
            }
        }
    }

    init(eventType: EventType, actor: String, description: String, emailIDs: [UUID] = [], hashBefore: String? = nil, hashAfter: String? = nil) {
        self.id = UUID()
        self.date = Date()
        self.eventType = eventType
        self.actor = actor
        self.description = description
        self.emailIDs = emailIDs
        self.hashBefore = hashBefore
        self.hashAfter = hashAfter
    }
}

// MARK: - Integrity Report

struct IntegrityReport {
    let totalChecked: Int
    let passed: Int
    let failed: Int
    let newlySealed: Int
    let failedIDs: [UUID]
    let timestamp: Date

    var isClean: Bool { failed == 0 }
}

// MARK: - Chain of Custody Manager

@MainActor
final class ChainOfCustodyManager: ObservableObject {
    static let shared = ChainOfCustodyManager()

    @Published var events: [CustodyEvent] = []

    private let storageKey = "mailin_chainOfCustody"

    private init() {
        loadEvents()
    }

    func recordEvent(type: CustodyEvent.EventType, actor: String, description: String, emailIDs: [UUID] = [], hashBefore: String? = nil, hashAfter: String? = nil) {
        let event = CustodyEvent(eventType: type, actor: actor, description: description, emailIDs: emailIDs, hashBefore: hashBefore, hashAfter: hashAfter)
        events.append(event)
        saveEvents()
        if LegalStateMirror.isEnabled { LegalStateMirror.shared.scheduleSync() }   // §3-F4 dual-write
        ForensicManager.shared.logAction("Chain of Custody: \(type.rawValue)", detail: description)
    }

    func verifyIntegrity(of emails: [MBOXParser.RawEmail]) async -> IntegrityReport {
        let forensic = ForensicManager.shared
        var failedIDs: [UUID] = []

        // Load the ORIGINAL seals from the store first. Without this, an email
        // outside the in-memory window looked unsealed, was "sealed" with its
        // current content, and then verified against itself — a tampered
        // email passed.
        await forensic.prefetchForensicWindow(ids: emails.map(\.id))

        // Seal only emails that truly have no stored seal yet; they are new
        // baselines, not verifications.
        let unsealed = emails.filter { forensic.perEmailHashes[$0.id] == nil }
        let unsealedIDs = Set(unsealed.map(\.id))
        if !unsealed.isEmpty {
            forensic.storeEmailHashes(unsealed)
        }

        for email in emails where !unsealedIDs.contains(email.id) {
            let result = forensic.verifyEmailIntegrity(email)
            if !result.passed {
                failedIDs.append(email.id)
            }
        }
        let newlySealed = unsealed.count

        return IntegrityReport(
            totalChecked: emails.count,
            passed: emails.count - newlySealed - failedIDs.count,
            failed: failedIDs.count,
            newlySealed: newlySealed,
            failedIDs: failedIDs,
            timestamp: Date()
        )
    }

    func exportAuditTrail() -> Data {
        var csv = "Date,Event Type,Actor,Description,Email Count,Hash Before,Hash After\n"
        let formatter = ISO8601DateFormatter()

        func csvField(_ text: String) -> String {
            var val = text.replacingOccurrences(of: "\"", with: "\"\"")
            if let first = val.first, "=+@-\t\r".contains(first) { val = "'" + val }
            if val.contains(",") || val.contains("\"") || val.contains("\n") { return "\"\(val)\"" }
            return val
        }
        for event in events {
            let date = formatter.string(from: event.date)
            let type = event.eventType.rawValue
            let actor = csvField(event.actor)
            let desc = csvField(event.description)
            let count = event.emailIDs.count
            let before = event.hashBefore ?? ""
            let after = event.hashAfter ?? ""
            csv += "\(date),\(type),\(actor),\(desc),\(count),\(before),\(after)\n"
        }

        return csv.data(using: .utf8) ?? Data()
    }

    func generateCustodyReport() -> Data {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 54

        let titleFont = PlatformFont.systemFont(ofSize: 18, weight: .bold)
        let headingFont = PlatformFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = PlatformFont.systemFont(ofSize: 10, weight: .regular)
        let captionFont = PlatformFont.systemFont(ofSize: 8, weight: .medium)

        #if os(macOS)
        let labelColor = NSColor(white: 0.1, alpha: 1.0)
        let secondaryColor = NSColor(white: 0.4, alpha: 1.0)
        #else
        let labelColor = UIColor(white: 0.1, alpha: 1.0)
        let secondaryColor = UIColor(white: 0.4, alpha: 1.0)
        #endif

        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: labelColor]
        let headingAttrs: [NSAttributedString.Key: Any] = [.font: headingFont, .foregroundColor: labelColor]
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: labelColor]
        let captionAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: secondaryColor]

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        var currentY: CGFloat = 0

        func startPage() {
            context.beginPage(mediaBox: &mediaBox)
            #if os(macOS)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            #else
            UIGraphicsPushContext(context)
            #endif
            currentY = pageHeight - margin
        }

        func endPage() {
            #if os(macOS)
            NSGraphicsContext.current = nil
            #else
            UIGraphicsPopContext()
            #endif
            context.endPage()
        }

        func drawText(_ text: String, attrs: [NSAttributedString.Key: Any]) {
            let contentWidth = pageWidth - margin * 2
            let nsText = text as NSString
            let size = nsText.boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
            let h = ceil(size.height)
            if currentY - h < margin + 20 {
                endPage()
                startPage()
            }
            nsText.draw(in: CGRect(x: margin, y: currentY - h, width: contentWidth, height: h), withAttributes: attrs)
            currentY -= (h + 4)
        }

        startPage()

        drawText("Chain of Custody Report", attrs: titleAttrs)
        currentY -= 12
        drawText("Generated: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))", attrs: captionAttrs)
        drawText("Total Events: \(events.count)", attrs: bodyAttrs)
        currentY -= 16

        drawText("Event Log", attrs: headingAttrs)
        currentY -= 8

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        for event in events {
            drawText("[\(dateFormatter.string(from: event.date))] \(event.eventType.rawValue)", attrs: headingAttrs)
            drawText("Actor: \(event.actor)", attrs: bodyAttrs)
            drawText("Description: \(event.description)", attrs: bodyAttrs)
            if !event.emailIDs.isEmpty {
                drawText("Emails affected: \(event.emailIDs.count)", attrs: bodyAttrs)
            }
            if let hash = event.hashAfter {
                drawText("Hash: \(hash)", attrs: captionAttrs)
            }
            currentY -= 8
        }

        endPage()
        context.closePDF()
        return pdfData as Data
    }

    func clearAllEvents() {
        events.removeAll()
        saveEvents()
    }

    // MARK: - Persistence

    private func saveEvents() {
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadEvents() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CustodyEvent].self, from: data) else { return }
        events = decoded
    }

}

// MARK: - Chain of Custody View

struct ChainOfCustodyView: View {
    let emails: [MBOXParser.RawEmail]
    var isPresented: Binding<Bool>?
    @ObservedObject private var custodyManager = ChainOfCustodyManager.shared
    @State private var showRecordEvent = false
    @State private var integrityReport: IntegrityReport?
    @State private var isVerifying = false
    @State private var showTutorial = false
    @Environment(\.dismiss) private var envDismiss
    #if os(iOS)
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    #endif
    @State private var exportStatus: String?
    // §3-L7: whole-scope verification when the 3.0 engine is on.
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    @Environment(\.archiveScope) private var scope
    private var v3: Bool { modules?.isOn(.v3ChainOfCustody) ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if v3 { WholeScopeNote().padding(.horizontal, Spacing.medium).padding(.top, Spacing.xSmall) }

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    integritySection
                    actionsSection
                    eventsSection
                }
                .padding(Spacing.medium)
            }
        }
        .featureTutorial(.chainOfCustody, key: "chain_of_custody_tutorial_seen", isPresented: $showTutorial)
        .sheet(isPresented: $showRecordEvent) {
            RecordEventSheet()
        }
        #if os(macOS)
        .toolWindowFrame()
        #else
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
    }

    private var header: some View {
        HStack {
            Image(systemName: "link.badge.plus")
                .foregroundColor(AppColors.primary)
            Text("Chain of Custody")
                .font(Typography.headline)
            Spacer()
            Text("\(custodyManager.events.count) events")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
            TutorialHelpButton(showTutorial: $showTutorial)
            if isPresented != nil {
                Button("Done") { closeSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private var integritySection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Integrity Verification")
                .font(Typography.subheadline)
                .fontWeight(.semibold)

            if let report = integrityReport {
                HStack(spacing: Spacing.medium) {
                    VStack {
                        Text("\(report.totalChecked)")
                            .font(Typography.title3)
                            .fontWeight(.bold)
                        Text("Checked")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                    VStack {
                        Text("\(report.passed)")
                            .font(Typography.title3)
                            .fontWeight(.bold)
                            .foregroundColor(AppColors.success)
                        Text("Passed")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                    if report.newlySealed > 0 {
                        VStack {
                            Text("\(report.newlySealed)")
                                .font(Typography.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                            Text("Sealed")
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                        }
                    }
                    VStack {
                        Text("\(report.failed)")
                            .font(Typography.title3)
                            .fontWeight(.bold)
                            .foregroundColor(report.failed > 0 ? AppColors.error : AppColors.success)
                        Text("Failed")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                verificationExplanation(report)
            }

            Button {
                verifyIntegrity()
            } label: {
                HStack {
                    if isVerifying {
                        ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                    }
                    Text(isVerifying ? String(localized: "Verifying...") : String(localized: "Verify Integrity"))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isVerifying || (!v3 && emails.isEmpty))
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.small) {
                Button("Record Event") { showRecordEvent = true }
                    .buttonStyle(SecondaryButtonStyle())

                Button("Export Audit Trail") { exportAuditTrail() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(custodyManager.events.isEmpty)

                Button("Export PDF Report") { exportPDFReport() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(custodyManager.events.isEmpty)

                if modules?.isOn(.v3Fingerprints) ?? false {
                    // §3-E2: per-email hash-tree proofs to the archive root.
                    Button(String(localized: "Export Evidence Record")) {
                        Task { @MainActor in
                            let (outcome, n) = await EvidenceRecordExporter.export(scope: scope)
                            exportStatus = outcome.message(String(localized: "Evidence record")) + (outcome.succeeded ? " (\(n))" : "")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Every email in scope with a hash-tree proof to the archive fingerprint — verifiable with SHA-256 alone")
                }

                if modules?.isOn(.v3PreservationExport) ?? false {
                    // §3-E5: BagIt + PREMIS preservation package.
                    Button(String(localized: "Export Preservation Package")) { exportPreservationPackage() }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("A BagIt bag with every original message and PREMIS metadata — the archival standard")
                }
            }
            if let exportStatus {
                Text(exportStatus)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Event Timeline")
                .font(Typography.subheadline)
                .fontWeight(.semibold)

            if custodyManager.events.isEmpty {
                EmptyStateView(
                    icon: "clock.badge.checkmark",
                    title: "No Events Recorded",
                    message: "Record custody events to build a verifiable chain of custody."
                )
            } else {
                ForEach(custodyManager.events.reversed()) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: CustodyEvent) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: event.eventType.icon)
                .foregroundColor(event.eventType.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                HStack {
                    Text(LocalizedStringKey(event.eventType.rawValue))
                        .font(Typography.callout)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(event.date, style: .date)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
                Text(event.description)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                Text("Actor: \(event.actor)")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                if !event.emailIDs.isEmpty {
                    Text("\(event.emailIDs.count) email\(event.emailIDs.count == 1 ? "" : "s")")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }
        }
        .padding(Spacing.small)
        .background(AppColors.backgroundSecondary)
        .cornerRadius(CornerRadius.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.eventType.rawValue) by \(event.actor): \(event.description)")
    }

    @ViewBuilder
    private func verificationExplanation(_ report: IntegrityReport) -> some View {
        if report.failed == 0 && report.newlySealed == 0 {
            Label {
                Text("All emails verified — SHA-256 hashes match the sealed originals. No tampering detected.")
                    .font(Typography.caption1)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(AppColors.success)
            }
            .padding(Spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.success.opacity(0.1))
            .cornerRadius(CornerRadius.small)
        } else if report.failed == 0 && report.newlySealed > 0 {
            Label {
                Text("\(report.newlySealed) email\(report.newlySealed == 1 ? " was" : "s were") sealed for the first time — SHA-256 hashes computed and stored as baseline. Run verification again to confirm integrity against these baselines.")
                    .font(Typography.caption1)
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.blue)
            }
            .padding(Spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(CornerRadius.small)
        } else {
            Label {
                Text("\(report.failed) email\(report.failed == 1 ? "" : "s") failed — SHA-256 hash does not match the sealed original. This may indicate the email content was modified after import.")
                    .font(Typography.caption1)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(AppColors.error)
            }
            .padding(Spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.error.opacity(0.1))
            .cornerRadius(CornerRadius.small)
        }
    }

    private func exportPreservationPackage() {
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let name = "mailin-preservation-\(stamp)"
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Create Package Here")
        guard panel.runModal() == .OK, let parent = panel.url else { exportStatus = String(localized: "Preservation package not saved — cancelled."); return }
        let bag = parent.appendingPathComponent(name, isDirectory: true)
        #else
        let bag = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: bag)
        #endif
        exportStatus = String(localized: "Building the preservation package…")
        Task { @MainActor in
            do {
                let r = try await PreservationExporter.export(scope: scope, to: bag,
                                                              organization: ForensicManager.shared.examinerName)
                exportStatus = String(localized: "Preservation package: \(r.originals) originals") +
                    (r.withoutOriginal > 0 ? String(localized: ", \(r.withoutOriginal) without a stored original") : "") +
                    (r.verified ? String(localized: " — every file verified.") : String(localized: " — VERIFICATION FAILED, do not rely on this package."))
                #if os(iOS)
                if r.verified { _ = PlatformExport.share(bag) }
                #endif
                if r.verified {
                    _ = await DocumentRegistry.post(.export, summary: "Preservation package — \(r.originals) originals", refs: bag.lastPathComponent)
                }
            } catch {
                exportStatus = String(localized: "Preservation package failed: \(error.localizedDescription)")
            }
        }
    }

    private func verifyIntegrity() {
        if v3 {
            isVerifying = true
            Task { @MainActor in
                defer { isVerifying = false }
                do {
                    let (state, receipt) = try await EDiscoveryEngine.verifyCollection(scope: scope, capability: .v3ChainOfCustody)
                    integrityReport = IntegrityReport(
                        totalChecked: receipt.processed, passed: state.passed, failed: state.failed,
                        newlySealed: state.newlySealed, failedIDs: state.failedIDs, timestamp: receipt.finishedAt)
                    custodyManager.recordEvent(
                        type: .accessed, actor: ForensicManager.shared.examinerName.isEmpty ? "mailin" : ForensicManager.shared.examinerName,
                        description: "Integrity verification: \(state.passed) passed, \(state.failed) failed, \(state.newlySealed) newly sealed — \(receipt.coverageLine)",
                        emailIDs: state.failedIDs)
                    await ScopeJob.recordReceipt(receipt, registry: modules)
                } catch {
                    exportStatus = error.localizedDescription
                }
            }
            return
        }
        isVerifying = true
        let emailsCopy = emails
        Task.detached {
            let report = await ChainOfCustodyManager.shared.verifyIntegrity(of: emailsCopy)
            await MainActor.run {
                integrityReport = report
                isVerifying = false
            }
        }
    }

    #if os(macOS)
    /// Save, read back, then sign with a `.sig` sidecar — the same
    /// tamper-evidence the iOS share path has always produced.
    private func saveSigned(_ data: Data, name: String, auditAction: String) {
        let outcome = PlatformExport.save(data: data, suggestedName: name)
        guard let url = outcome.url else {
            exportStatus = outcome.message(name)
            return
        }
        do {
            let sig = try ExportSigner.shared.signFile(url)
            exportStatus = String(localized: "Saved \(url.lastPathComponent) and its signature \(sig.lastPathComponent).")
            _ = try? HMACChainAuditLog.shared.append(action: auditAction, detail: "\(url.lastPathComponent) saved and signed")
        } catch {
            exportStatus = String(localized: "Saved \(url.lastPathComponent), but it could not be signed: \(error.localizedDescription)")
            _ = try? HMACChainAuditLog.shared.append(action: auditAction, detail: "\(url.lastPathComponent) saved UNSIGNED: \(error.localizedDescription)")
        }
    }
    #endif

    private func exportAuditTrail() {
        let data = custodyManager.exportAuditTrail()
        #if os(macOS)
        saveSigned(data, name: "chain_of_custody_audit.csv", auditAction: "export.auditTrail")
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chain_of_custody_audit.csv")
        do {
            try data.write(to: url, options: .atomic)
            // Tamper-evident signing: produce a .sig sidecar so recipients
            // can verify the audit trail was not modified after export.
            if let sig = try? ExportSigner.shared.signFile(url) {
                shareItems = [url, sig]
            } else {
                shareItems = [url]
            }
            showShareSheet = true
            _ = try? HMACChainAuditLog.shared.append(
                action: "export.auditTrail",
                detail: "chain_of_custody_audit.csv signed and shared"
            )
        } catch {
            // Best-effort; share sheet won't present if write fails.
        }
        #endif
    }

    private func exportPDFReport() {
        let data = custodyManager.generateCustodyReport()
        #if os(macOS)
        saveSigned(data, name: "chain_of_custody_report.pdf", auditAction: "export.custodyReport")
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chain_of_custody_report.pdf")
        do {
            try data.write(to: url, options: .atomic)
            if let sig = try? ExportSigner.shared.signFile(url) {
                shareItems = [url, sig]
            } else {
                shareItems = [url]
            }
            showShareSheet = true
            _ = try? HMACChainAuditLog.shared.append(
                action: "export.custodyReport",
                detail: "chain_of_custody_report.pdf signed and shared"
            )
        } catch {
            // Best-effort; share sheet won't present if write fails.
        }
        #endif
    }
}

// MARK: - Record Event Sheet

struct RecordEventSheet: View {
    @ObservedObject private var custodyManager = ChainOfCustodyManager.shared
    @State private var eventType: CustodyEvent.EventType = .accessed
    @State private var actor = ""
    @State private var description = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Record Custody Event")
                    .font(Typography.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.medium)

            Divider()

            VStack(alignment: .leading, spacing: Spacing.medium) {
                Picker("Event Type", selection: $eventType) {
                    ForEach(CustodyEvent.EventType.allCases, id: \.self) { type in
                        Label(type.rawValue, systemImage: type.icon).tag(type)
                    }
                }

                TextField("Actor (e.g., examiner name)", text: $actor)
                    .textFieldStyle(.roundedBorder)

                TextField("Description", text: $description)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Record") {
                        custodyManager.recordEvent(
                            type: eventType,
                            actor: actor.isEmpty ? "Unknown" : actor,
                            description: description
                        )
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(Spacing.medium)

            Spacer()
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }
}
