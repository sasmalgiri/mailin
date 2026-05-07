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
        ForensicManager.shared.logAction("Chain of Custody: \(type.rawValue)", detail: description)
    }

    func verifyIntegrity(of emails: [MBOXParser.RawEmail]) -> IntegrityReport {
        var failedIDs: [UUID] = []

        for email in emails {
            let result = ForensicManager.shared.verifyEmailIntegrity(email)
            if !result.passed {
                failedIDs.append(email.id)
            }
        }

        return IntegrityReport(
            totalChecked: emails.count,
            passed: emails.count - failedIDs.count,
            failed: failedIDs.count,
            failedIDs: failedIDs,
            timestamp: Date()
        )
    }

    func exportAuditTrail() -> Data {
        var csv = "Date,Event Type,Actor,Description,Email Count,Hash Before,Hash After\n"
        let formatter = ISO8601DateFormatter()

        for event in events {
            let date = formatter.string(from: event.date)
            let type = event.eventType.rawValue
            let actor = event.actor.replacingOccurrences(of: ",", with: ";")
            let desc = event.description.replacingOccurrences(of: ",", with: ";")
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
        let labelColor = PlatformColor.labelColor
        let secondaryColor = PlatformColor.secondaryLabelColor
        #else
        let labelColor = PlatformColor.label
        let secondaryColor = PlatformColor.secondaryLabel
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
    @ObservedObject private var custodyManager = ChainOfCustodyManager.shared
    @State private var showRecordEvent = false
    @State private var integrityReport: IntegrityReport?
    @State private var isVerifying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    integritySection
                    actionsSection
                    eventsSection
                }
                .padding(Spacing.medium)
            }
        }
        .sheet(isPresented: $showRecordEvent) {
            RecordEventSheet()
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
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
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.medium)
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
            }

            Button {
                verifyIntegrity()
            } label: {
                HStack {
                    if isVerifying {
                        ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                    }
                    Text(isVerifying ? "Verifying..." : "Verify Integrity")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isVerifying || emails.isEmpty)
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    private var actionsSection: some View {
        HStack(spacing: Spacing.small) {
            Button("Record Event") { showRecordEvent = true }
                .buttonStyle(SecondaryButtonStyle())

            Button("Export Audit Trail") { exportAuditTrail() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(custodyManager.events.isEmpty)

            Button("Export PDF Report") { exportPDFReport() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(custodyManager.events.isEmpty)
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
                    Text(event.eventType.rawValue)
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

    private func verifyIntegrity() {
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

    private func exportAuditTrail() {
        let data = custodyManager.exportAuditTrail()
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "chain_of_custody_audit.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? data.write(to: url, options: .atomic)
            }
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chain_of_custody_audit.csv")
        try? data.write(to: url, options: .atomic)
        #endif
    }

    private func exportPDFReport() {
        let data = custodyManager.generateCustodyReport()
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "chain_of_custody_report.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? data.write(to: url, options: .atomic)
            }
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chain_of_custody_report.pdf")
        try? data.write(to: url, options: .atomic)
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
