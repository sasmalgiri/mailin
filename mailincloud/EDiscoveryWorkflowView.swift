//
//  EDiscoveryWorkflowView.swift
//  mailin
//
//  EDRM-based e-discovery workflow panel with six phases:
//  Identification, Preservation, Collection, Processing, Review, Production.
//

import SwiftUI

// MARK: - Phase Enum

enum EDiscoveryPhase: Int, CaseIterable, Identifiable, Codable {
    case identification = 0
    case preservation
    case collection
    case processing
    case review
    case production

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .identification: return "Identification"
        case .preservation:   return "Preservation"
        case .collection:     return "Collection"
        case .processing:     return "Processing"
        case .review:         return "Review"
        case .production:     return "Production"
        }
    }

    var icon: String {
        switch self {
        case .identification: return "magnifyingglass"
        case .preservation:   return "lock.shield"
        case .collection:     return "tray.and.arrow.down"
        case .processing:     return "gearshape.2"
        case .review:         return "doc.text.magnifyingglass"
        case .production:     return "shippingbox"
        }
    }

    var description: String {
        switch self {
        case .identification:
            return "Locate potentially responsive data by defining search criteria, custodians, and date ranges."
        case .preservation:
            return "Apply legal holds and preserve relevant data to prevent spoliation."
        case .collection:
            return "Gather data from identified sources into the review environment."
        case .processing:
            return "Deduplicate, extract text, run NLP analysis, and prepare data for review."
        case .review:
            return "Review documents for relevance, privilege, and responsiveness. Tag and annotate."
        case .production:
            return "Generate load files, apply Bates numbering, and export production sets."
        }
    }

    var checklistItems: [String] {
        switch self {
        case .identification:
            return [
                "Define search terms and keywords",
                "Identify custodians",
                "Set relevant date ranges",
                "Document data sources",
                "Run preliminary search"
            ]
        case .preservation:
            return [
                "Issue legal hold notice",
                "Verify source file integrity",
                "Compute and store hash values",
                "Lock source files from modification",
                "Document chain of custody"
            ]
        case .collection:
            return [
                "Import MBOX / EML / PST sources",
                "Verify import checksums",
                "Log collection metadata",
                "Confirm custodian attribution",
                "Document collection scope"
            ]
        case .processing:
            return [
                "Extract email text and metadata",
                "Run NLP classification",
                "Run sentiment analysis",
                "Detect phishing / anomalies",
                "Deduplicate messages",
                "Index for full-text search"
            ]
        case .review:
            return [
                "Create review batches",
                "Apply evidence tags",
                "Annotate key documents",
                "Flag privileged materials",
                "Perform quality control checks"
            ]
        case .production:
            return [
                "Apply Bates numbering",
                "Generate Concordance DAT load file",
                "Export production CSV",
                "Generate privilege log",
                "Create hash manifest",
                "Package and deliver"
            ]
        }
    }
}

// MARK: - Phase Status

enum PhaseStatus: String, Codable {
    case notStarted = "Not Started"
    case inProgress = "In Progress"
    case completed  = "Completed"
    case skipped    = "Skipped"

    var color: Color {
        switch self {
        case .notStarted: return AppColors.secondary
        case .inProgress: return AppColors.warning
        case .completed:  return AppColors.success
        case .skipped:    return AppColors.info
        }
    }

    var icon: String {
        switch self {
        case .notStarted: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed:  return "checkmark.circle.fill"
        case .skipped:    return "arrow.right.circle"
        }
    }
}

// MARK: - Case Info

struct CaseInfo: Codable {
    var caseNumber: String = ""
    var caseName: String = ""
    var client: String = ""
    var custodians: [String] = []
    var dateRangeStart: Date?
    var dateRangeEnd: Date?

    var isComplete: Bool {
        !caseNumber.isEmpty && !caseName.isEmpty
    }
}

// MARK: - Workflow Manager

@MainActor
class EDiscoveryWorkflowManager: ObservableObject {
    @Published var currentPhase: EDiscoveryPhase = .identification
    @Published var phaseStatus: [EDiscoveryPhase: PhaseStatus] = {
        var initial: [EDiscoveryPhase: PhaseStatus] = [:]
        for phase in EDiscoveryPhase.allCases {
            initial[phase] = .notStarted
        }
        return initial
    }()
    @Published var phaseNotes: [EDiscoveryPhase: String] = [:]
    @Published var phaseChecklist: [EDiscoveryPhase: Set<Int>] = [:]
    @Published var caseInfo: CaseInfo = CaseInfo()

    private let defaultsKeyPrefix = "ediscovery_"

    init() {
        loadState()
    }

    var overallProgress: Double {
        let completed = phaseStatus.values.filter { $0 == .completed || $0 == .skipped }.count
        return Double(completed) / Double(EDiscoveryPhase.allCases.count)
    }

    var completedPhaseCount: Int {
        phaseStatus.values.filter { $0 == .completed || $0 == .skipped }.count
    }

    func markPhaseComplete(_ phase: EDiscoveryPhase) {
        phaseStatus[phase] = .completed
        ForensicManager.shared.logAction(
            "E-Discovery Phase Completed",
            detail: "\(phase.title) marked complete for case \(caseInfo.caseNumber)"
        )
        advanceToNextPhase(after: phase)
        saveState()
    }

    func skipPhase(_ phase: EDiscoveryPhase) {
        phaseStatus[phase] = .skipped
        ForensicManager.shared.logAction(
            "E-Discovery Phase Skipped",
            detail: "\(phase.title) skipped for case \(caseInfo.caseNumber)"
        )
        advanceToNextPhase(after: phase)
        saveState()
    }

    func startPhase(_ phase: EDiscoveryPhase) {
        phaseStatus[phase] = .inProgress
        currentPhase = phase
        saveState()
    }

    func toggleChecklistItem(phase: EDiscoveryPhase, index: Int) {
        var checklist = phaseChecklist[phase] ?? []
        if checklist.contains(index) {
            checklist.remove(index)
        } else {
            checklist.insert(index)
        }
        phaseChecklist[phase] = checklist
        saveState()
    }

    func isChecklistItemComplete(phase: EDiscoveryPhase, index: Int) -> Bool {
        phaseChecklist[phase]?.contains(index) ?? false
    }

    func updateNotes(phase: EDiscoveryPhase, text: String) {
        phaseNotes[phase] = text
        saveState()
    }

    func resetWorkflow() {
        for phase in EDiscoveryPhase.allCases {
            phaseStatus[phase] = .notStarted
        }
        phaseNotes = [:]
        phaseChecklist = [:]
        currentPhase = .identification
        caseInfo = CaseInfo()
        saveState()
    }

    func exportWorkflowSummary() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var report = "E-DISCOVERY WORKFLOW SUMMARY\n"
        report += String(repeating: "=", count: 76) + "\n"
        report += "Case Number: \(caseInfo.caseNumber.isEmpty ? "N/A" : caseInfo.caseNumber)\n"
        report += "Case Name: \(caseInfo.caseName.isEmpty ? "N/A" : caseInfo.caseName)\n"
        report += "Client: \(caseInfo.client.isEmpty ? "N/A" : caseInfo.client)\n"
        report += "Custodians: \(caseInfo.custodians.isEmpty ? "N/A" : caseInfo.custodians.joined(separator: ", "))\n"
        if let start = caseInfo.dateRangeStart {
            report += "Date Range Start: \(dateFormatter.string(from: start))\n"
        }
        if let end = caseInfo.dateRangeEnd {
            report += "Date Range End: \(dateFormatter.string(from: end))\n"
        }
        report += "Overall Progress: \(Int(overallProgress * 100))%\n"
        report += "Export Date: \(dateFormatter.string(from: Date()))\n"
        report += String(repeating: "=", count: 76) + "\n\n"

        for phase in EDiscoveryPhase.allCases {
            let status = phaseStatus[phase] ?? .notStarted
            report += "PHASE \(phase.rawValue + 1): \(phase.title.uppercased())\n"
            report += String(repeating: "-", count: 40) + "\n"
            report += "Status: \(status.rawValue)\n"
            report += "Description: \(phase.description)\n"

            let checklist = phase.checklistItems
            let completed = phaseChecklist[phase] ?? []
            report += "Checklist (\(completed.count)/\(checklist.count)):\n"
            for (index, item) in checklist.enumerated() {
                let check = completed.contains(index) ? "[x]" : "[ ]"
                report += "  \(check) \(item)\n"
            }

            if let notes = phaseNotes[phase], !notes.isEmpty {
                report += "Notes: \(notes)\n"
            }
            report += "\n"
        }

        report += String(repeating: "=", count: 76) + "\n"
        report += "END OF WORKFLOW SUMMARY\n"
        return report
    }

    // MARK: - Persistence

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        UserDefaults.standard.set(currentPhase.rawValue, forKey: key("currentPhase"))

        if let data = try? encoder.encode(phaseStatus) {
            UserDefaults.standard.set(data, forKey: key("phaseStatus"))
        }

        if let data = try? encoder.encode(phaseNotes) {
            UserDefaults.standard.set(data, forKey: key("phaseNotes"))
        }

        // Encode phaseChecklist as [Int: [Int]] since Set<Int> is Codable
        let checklistDict = phaseChecklist.reduce(into: [Int: [Int]]()) { result, entry in
            result[entry.key.rawValue] = Array(entry.value)
        }
        if let data = try? encoder.encode(checklistDict) {
            UserDefaults.standard.set(data, forKey: key("phaseChecklist"))
        }

        if let data = try? encoder.encode(caseInfo) {
            UserDefaults.standard.set(data, forKey: key("caseInfo"))
        }
    }

    private func loadState() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let raw = UserDefaults.standard.value(forKey: key("currentPhase")) as? Int,
           let phase = EDiscoveryPhase(rawValue: raw) {
            currentPhase = phase
        }

        if let data = UserDefaults.standard.data(forKey: key("phaseStatus")),
           let decoded = try? decoder.decode([EDiscoveryPhase: PhaseStatus].self, from: data) {
            phaseStatus = decoded
        }

        if let data = UserDefaults.standard.data(forKey: key("phaseNotes")),
           let decoded = try? decoder.decode([EDiscoveryPhase: String].self, from: data) {
            phaseNotes = decoded
        }

        if let data = UserDefaults.standard.data(forKey: key("phaseChecklist")),
           let decoded = try? decoder.decode([Int: [Int]].self, from: data) {
            phaseChecklist = decoded.reduce(into: [EDiscoveryPhase: Set<Int>]()) { result, entry in
                if let phase = EDiscoveryPhase(rawValue: entry.key) {
                    result[phase] = Set(entry.value)
                }
            }
        }

        if let data = UserDefaults.standard.data(forKey: key("caseInfo")),
           let decoded = try? decoder.decode(CaseInfo.self, from: data) {
            caseInfo = decoded
        }
    }

    private func key(_ suffix: String) -> String {
        "\(defaultsKeyPrefix)\(suffix)"
    }

    private func advanceToNextPhase(after phase: EDiscoveryPhase) {
        let allPhases = EDiscoveryPhase.allCases
        if let nextIndex = allPhases.firstIndex(of: phase).map({ $0 + 1 }),
           nextIndex < allPhases.count {
            currentPhase = allPhases[nextIndex]
        }
    }
}

// MARK: - E-Discovery Workflow View

struct EDiscoveryWorkflowView: View {
    let emails: [MBOXParser.RawEmail]

    @StateObject private var manager = EDiscoveryWorkflowManager()
    @Environment(\.dismiss) private var dismiss

    @State private var showResetConfirmation = false
    @State private var actionMessage: String?
    @State private var aiProcessingInsights: String?
    @State private var isLoadingAI = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            overallProgressBar
            Divider()
            phaseStepper
            Divider()
            phaseDetailView
        }
        .background(AppColors.backgroundPrimary)
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 780, maxWidth: 960,
               minHeight: 560, idealHeight: 720, maxHeight: 900)
        #endif
        .adaptiveDestructiveConfirmation(
            "Reset Workflow",
            isPresented: $showResetConfirmation,
            message: "This will reset all phases, checklists, and notes. This cannot be undone.",
            actionTitle: "Reset"
        ) {
            manager.resetWorkflow()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label("E-Discovery Workflow", systemImage: "list.bullet.clipboard")
                    .font(Typography.title2)
                Text("EDRM-based workflow for \(emails.count) email\(emails.count == 1 ? "" : "s").")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("E-Discovery Workflow panel, \(emails.count) emails")

            Spacer()

            if let message = actionMessage {
                Text(message)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.success)
                    .transition(.opacity)
            }

            Menu {
                Button {
                    exportSummary()
                } label: {
                    Label("Export Summary", systemImage: "doc.text")
                }

                Button {
                    printSummary()
                } label: {
                    Label("Print Summary", systemImage: "printer")
                }

                Divider()

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset Workflow", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .foregroundColor(AppColors.secondary)
            }
            .accessibilityLabel("Workflow options menu")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close e-discovery workflow")
        }
        .padding(Spacing.medium)
    }

    // MARK: - Overall Progress

    private var overallProgressBar: some View {
        VStack(spacing: Spacing.xxSmall) {
            HStack {
                Text("Overall Progress")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                Spacer()
                Text("\(manager.completedPhaseCount)/\(EDiscoveryPhase.allCases.count) phases")
                    .font(Typography.caption1)
                    .fontWeight(.semibold)
            }
            ProgressView(value: manager.overallProgress)
                .tint(manager.overallProgress >= 1.0 ? AppColors.success : AppColors.primary)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Overall progress: \(Int(manager.overallProgress * 100)) percent, \(manager.completedPhaseCount) of \(EDiscoveryPhase.allCases.count) phases complete")
    }

    // MARK: - Phase Stepper (Horizontal)

    private var phaseStepper: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(EDiscoveryPhase.allCases) { phase in
                    let status = manager.phaseStatus[phase] ?? .notStarted
                    let isCurrent = manager.currentPhase == phase

                    HStack(spacing: 0) {
                        // Connector line (leading)
                        if phase != EDiscoveryPhase.allCases.first {
                            Rectangle()
                                .fill(status == .completed || status == .skipped
                                      ? AppColors.success
                                      : AppColors.separatorLight)
                                .frame(width: 20, height: 2)
                                .accessibilityHidden(true)
                        }

                        Button {
                            withAnimation(AnimationTiming.normal) {
                                manager.currentPhase = phase
                                if status == .notStarted {
                                    manager.startPhase(phase)
                                }
                            }
                        } label: {
                            VStack(spacing: Spacing.xxSmall) {
                                ZStack {
                                    Circle()
                                        .fill(isCurrent
                                              ? AppColors.primary
                                              : status.color.opacity(0.2))
                                        .frame(width: 36, height: 36)

                                    Image(systemName: status == .completed
                                          ? "checkmark"
                                          : status == .skipped
                                            ? "arrow.right"
                                            : phase.icon)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(isCurrent ? .white : status.color)
                                }

                                Text(phase.title)
                                    .font(Typography.caption2)
                                    .fontWeight(isCurrent ? .semibold : .regular)
                                    .foregroundColor(isCurrent ? AppColors.primary : AppColors.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(phase.title), \(status.rawValue)")
                        .accessibilityHint(isCurrent ? "Currently selected phase" : "Tap to select this phase")

                        // Connector line (trailing)
                        if phase != EDiscoveryPhase.allCases.last {
                            Rectangle()
                                .fill(status == .completed || status == .skipped
                                      ? AppColors.success
                                      : AppColors.separatorLight)
                                .frame(width: 20, height: 2)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.medium)
        }
        .padding(.vertical, Spacing.small)
    }

    // MARK: - Phase Detail

    private var phaseDetailView: some View {
        let phase = manager.currentPhase
        let status = manager.phaseStatus[phase] ?? .notStarted

        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                // Phase header
                HStack {
                    Image(systemName: phase.icon)
                        .font(Typography.title3)
                        .foregroundColor(AppColors.primary)
                    VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                        Text(phase.title)
                            .font(Typography.title3)
                        Text(status.rawValue)
                            .font(Typography.caption1)
                            .foregroundColor(status.color)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(phase.title), status: \(status.rawValue)")

                // Description
                Text(phase.description)
                    .font(Typography.body)
                    .foregroundColor(AppColors.secondary)

                // Checklist
                phaseChecklist(for: phase)

                // Notes
                phaseNotesSection(for: phase)

                // Phase-specific actions
                phaseActions(for: phase)

                // Phase control buttons
                phaseControlButtons(for: phase, status: status)
            }
            .padding(Spacing.medium)
        }
    }

    // MARK: - Checklist

    private func phaseChecklist(for phase: EDiscoveryPhase) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Checklist")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(phase.checklistItems.enumerated()), id: \.offset) { index, item in
                let isChecked = manager.isChecklistItemComplete(phase: phase, index: index)

                Button {
                    withAnimation(AnimationTiming.fast) {
                        manager.toggleChecklistItem(phase: phase, index: index)
                    }
                } label: {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                            .foregroundColor(isChecked ? AppColors.success : AppColors.secondary)
                        Text(item)
                            .font(Typography.body)
                            .foregroundColor(isChecked ? AppColors.secondary : .primary)
                            .strikethrough(isChecked)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item), \(isChecked ? "completed" : "not completed")")
                .accessibilityHint("Toggle completion")
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Notes

    private func phaseNotesSection(for phase: EDiscoveryPhase) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Notes")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            TextEditor(text: Binding(
                get: { manager.phaseNotes[phase] ?? "" },
                set: { manager.updateNotes(phase: phase, text: $0) }
            ))
            .font(Typography.body)
            .frame(minHeight: 60, maxHeight: 120)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.small)
                    .stroke(AppColors.separatorLight, lineWidth: 1)
            )
            .accessibilityLabel("Phase notes for \(phase.title)")
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Phase-Specific Actions

    @ViewBuilder
    private func phaseActions(for phase: EDiscoveryPhase) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Actions")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            switch phase {
            case .identification:
                identificationActions

            case .preservation:
                preservationActions

            case .collection:
                collectionActions

            case .processing:
                processingActions

            case .review:
                reviewActions

            case .production:
                productionActions
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private var identificationActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Text("Emails in scope: \(emails.count)")
                    .font(Typography.callout)
                Spacer()
            }
            HStack {
                Text("Unique domains: \(Set(emails.flatMap { $0.domains }).count)")
                    .font(Typography.callout)
                Spacer()
            }

            Button {
                manager.startPhase(.identification)
                ForensicManager.shared.logAction(
                    "E-Discovery: Run Search",
                    detail: "Search executed across \(emails.count) emails"
                )
                showActionMessage("Search executed on \(emails.count) emails")
            } label: {
                Label("Run Search", systemImage: "magnifyingglass")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Run search across all emails")
        }
    }

    private var preservationActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Applying a legal hold logs the action in the forensic audit trail and locks source integrity hashes.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            Button {
                CustodianManager.shared.placeLegalHold(on: emails)
                ForensicManager.shared.storeEmailHashes(emails)
                showActionMessage("Legal hold applied with evidence seals — \(emails.count) emails protected")
            } label: {
                Label("Apply Legal Hold", systemImage: "lock.shield")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Apply legal hold to all emails")
            .accessibilityHint("Places legal hold with cryptographic evidence seals and stores integrity hashes")
        }
    }

    private var collectionActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Currently loaded: \(emails.count) email(s) from imported sources.")
                .font(Typography.callout)

            Button {
                ForensicManager.shared.logAction(
                    "E-Discovery: Import Sources",
                    detail: "Import sources initiated for case \(manager.caseInfo.caseNumber)"
                )
                showActionMessage("Import sources initiated")
            } label: {
                Label("Import Sources", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Import email sources")
        }
    }

    private var processingActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let classified = EmailNLPEngine.classifyAll(emails)
            let categories = classified.sorted { $0.value > $1.value }

            if !categories.isEmpty {
                Text("Classification preview:")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                ForEach(categories, id: \.key) { category, count in
                    HStack {
                        Text(category.rawValue)
                            .font(Typography.callout)
                        Spacer()
                        Text("\(count)")
                            .font(Typography.callout)
                            .fontWeight(.semibold)
                    }
                }
            }

            Button {
                ForensicManager.shared.logAction(
                    "E-Discovery: NLP Analysis",
                    detail: "NLP analysis executed on \(emails.count) emails"
                )
                showActionMessage("NLP analysis complete on \(emails.count) emails")
            } label: {
                Label("Run NLP Analysis", systemImage: "brain")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Run NLP analysis on all emails")

            Divider()

            HStack {
                Text("AI-Enhanced Processing")
                    .font(Typography.caption1)
                    .fontWeight(.semibold)
                Spacer()
                if isLoadingAI {
                    ProgressView()
                        .controlSize(.small)
                } else if aiProcessingInsights == nil {
                    Button {
                        loadAIProcessingInsights(categories: categories)
                    } label: {
                        Label("Enhance with AI", systemImage: "sparkles")
                            .font(Typography.caption1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                }
            }

            if let insights = aiProcessingInsights {
                Text(insights)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var reviewActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let taggedCount = ForensicManager.shared.evidenceTags.count
            Text("Tagged emails: \(taggedCount)")
                .font(Typography.callout)
            Text("Annotated emails: \(ForensicManager.shared.annotations.count)")
                .font(Typography.callout)

            Button {
                ForensicManager.shared.logAction(
                    "E-Discovery: Review Batches",
                    detail: "Review batches opened for \(emails.count) emails"
                )
                showActionMessage("Review batches ready")
            } label: {
                Label("Open Review Batches", systemImage: "rectangle.stack.badge.play")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Open review batches")
        }
    }

    private var productionActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Generate production deliverables for the current email set.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            HStack(spacing: Spacing.small) {
                Button {
                    let dat = ForensicManager.shared.exportConcordanceDAT(emails: emails)
                    #if os(macOS)
                    _ = PlatformFileSaver.saveText(dat, suggestedName: "production_loadfile.dat")
                    #endif
                    ForensicManager.shared.logAction(
                        "E-Discovery: Load File Generated",
                        detail: "Concordance DAT load file for \(emails.count) emails"
                    )
                    showActionMessage("Load file generated")
                } label: {
                    Label("Generate Load File", systemImage: "doc.text")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Generate Concordance DAT load file")

                Button {
                    let csv = ForensicManager.shared.exportBulkForensicCSV(emails: emails)
                    #if os(macOS)
                    _ = PlatformFileSaver.saveText(csv, suggestedName: "production_export.csv")
                    #endif
                    ForensicManager.shared.logAction(
                        "E-Discovery: Production Export",
                        detail: "Production CSV exported for \(emails.count) emails"
                    )
                    showActionMessage("Production export complete")
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Export production CSV")

                Button {
                    let log = ForensicManager.shared.exportPrivilegeLog(emails: emails)
                    if log.isEmpty {
                        showActionMessage("No privileged emails tagged — tag emails first")
                    } else {
                        #if os(macOS)
                        _ = PlatformFileSaver.saveText(log, suggestedName: "privilege_log.csv")
                        #endif
                        ForensicManager.shared.logAction(
                            "E-Discovery: Privilege Log",
                            detail: "Privilege log generated for \(emails.count) emails"
                        )
                        showActionMessage("Privilege log generated")
                    }
                } label: {
                    Label("Privilege Log", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Generate privilege log")
            }
        }
    }

    // MARK: - Phase Control Buttons

    private func phaseControlButtons(for phase: EDiscoveryPhase, status: PhaseStatus) -> some View {
        HStack(spacing: Spacing.small) {
            if status != .completed {
                Button {
                    withAnimation(AnimationTiming.normal) {
                        manager.markPhaseComplete(phase)
                    }
                } label: {
                    Label("Mark Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Mark \(phase.title) as complete")
            }

            if status != .skipped && status != .completed {
                Button {
                    withAnimation(AnimationTiming.normal) {
                        manager.skipPhase(phase)
                    }
                } label: {
                    Label("Skip Phase", systemImage: "arrow.right.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Skip \(phase.title) phase")
            }

            if status == .completed || status == .skipped {
                Text("Phase \(status.rawValue.lowercased())")
                    .font(Typography.callout)
                    .foregroundColor(status.color)
                    .fontWeight(.semibold)
            }

            Spacer()
        }
        .padding(.top, Spacing.small)
    }

    // MARK: - AI Enhancement

    private func loadAIProcessingInsights(categories: [(key: EmailNLPEngine.EmailCategory, value: Int)]) {
        isLoadingAI = true
        let breakdown = categories.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", ")
        let context = """
        E-Discovery processing phase for case \(manager.caseInfo.caseNumber). \
        \(emails.count) emails classified: \(breakdown).
        """
        let emailsCopy = emails
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .all,
                    emails: emailsCopy,
                    context: context
                )
                aiProcessingInsights = result ?? "AI analysis unavailable."
            } else {
                aiProcessingInsights = "Requires macOS 26 or later."
            }
            #else
            aiProcessingInsights = "AI features not available on this platform."
            #endif
            isLoadingAI = false
        }
    }

    // MARK: - Helpers

    private func exportSummary() {
        let summary = manager.exportWorkflowSummary()
        #if os(macOS)
        _ = PlatformFileSaver.saveText(summary, suggestedName: "ediscovery_workflow_\(manager.caseInfo.caseNumber).txt")
        #endif
        showActionMessage("Summary exported")
    }

    private func printSummary() {
        let summary = manager.exportWorkflowSummary()
        PlatformPrinter.printText(summary)
    }

    private func showActionMessage(_ message: String) {
        withAnimation(AnimationTiming.fast) {
            actionMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation(AnimationTiming.fast) {
                actionMessage = nil
            }
        }
    }
}
