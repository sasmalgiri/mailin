@testable import ArchiveCore
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
        case .identification: return String(localized: "Identification")
        case .preservation:   return String(localized: "Preservation")
        case .collection:     return String(localized: "Collection")
        case .processing:     return String(localized: "Processing")
        case .review:         return String(localized: "Review")
        case .production:     return String(localized: "Production")
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
            return String(localized: "Locate potentially responsive data by defining search criteria, custodians, and date ranges.")
        case .preservation:
            return String(localized: "Apply legal holds and preserve relevant data to prevent spoliation.")
        case .collection:
            return String(localized: "Gather data from identified sources into the review environment.")
        case .processing:
            return String(localized: "Deduplicate, extract text, run NLP analysis, and prepare data for review.")
        case .review:
            return String(localized: "Review documents for relevance, privilege, and responsiveness. Tag and annotate.")
        case .production:
            return String(localized: "Generate load files, apply Bates numbering, and export production sets.")
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
    var isPresented: Binding<Bool>?

    @StateObject private var manager = EDiscoveryWorkflowManager()
    @Environment(\.dismiss) private var envDismiss
    // §3-L1…L5: with the 3.0 engine on, actions cover the whole scope.
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    @Environment(\.archiveScope) private var scope
    @State private var scopeConfirm: ScopeConfirmationRequest?
    @State private var v3HeldCount: Int?
    @State private var v3Running = false
    /// §3-M3: prefixed to the next action message after a fallback.
    @State private var fallbackPrefix: String?
    /// §3-E2: a production was just saved; offer its evidence record.
    @State private var productionRecordOffered = false
    private var v3: Bool { modules?.isOn(.v3EDiscovery) ?? false }

    @State private var showResetConfirmation = false
    @State private var showingReleaseConfirmation = false
    @State private var showTutorial = false
    @State private var showPIIReport = false
    @State private var actionMessage: String?
    @State private var aiProcessingInsights: String?
    @State private var isLoadingAI = false

    // Identification
    @State private var identificationResults: (matching: Int, total: Int, topDomains: [(String, Int)])?
    // Collection
    @State private var collectionVerification: (passed: Int, failed: Int, unverified: Int)?
    @State private var isVerifyingCollection = false
    // Review
    @State private var reviewBatches: [(category: String, count: Int)]?
    /// NLP classification of the collection — computed by Run NLP Analysis
    /// (once), not re-run on every redraw of the view.
    @State private var nlpCategories: [(category: EmailNLPEngine.EmailCategory, count: Int)]?
    @State private var isRunningNLP = false
    @State private var privilegeScanCount = 0

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
        .toolWindowFrame()
        .adaptiveDestructiveConfirmation(
            "Reset Workflow",
            isPresented: $showResetConfirmation,
            message: String(localized: "This will reset all phases, checklists, and notes. This cannot be undone."),
            actionTitle: String(localized: "Reset")
        ) {
            manager.resetWorkflow()
        }
        .adaptiveDestructiveConfirmation(
            "Release Legal Hold",
            isPresented: $showingReleaseConfirmation,
            message: "This will remove legal hold protection from all \(scopeCount) emails. They will no longer be protected from modification or deletion. This action is logged in the forensic audit trail.",
            actionTitle: String(localized: "Release Hold")
        ) {
            if v3 {
                Task { @MainActor in
                    do {
                        let r = try await EDiscoveryEngine.releaseHold(scope: scope)
                        v3HeldCount = await EDiscoveryEngine.heldCount(scope: scope)
                        await ScopeJob.recordReceipt(r.receipt, registry: modules)
                        showActionMessage(String(localized: "Legal hold released — \(r.released) emails no longer protected"))
                    } catch is CancellationError {
                    } catch {
                        // §3-M3: the previous engine releases the loaded emails.
                        let note = EngineGuard.fellBack(.v3EDiscovery, error: error)
                        for email in emails { CustodianManager.shared.removeLegalHold(email.id) }
                        showActionMessage(note + " " + String(localized: "Legal hold released — \(emails.count) emails no longer protected"))
                    }
                }
                return
            }
            for email in emails {
                CustodianManager.shared.removeLegalHold(email.id)
            }
            showActionMessage("Legal hold released — \(emails.count) emails no longer protected")
        }
        .scopeConfirmation($scopeConfirm)
        .task(id: v3) { if v3 { v3HeldCount = await EDiscoveryEngine.heldCount(scope: scope) } }
        .sheet(isPresented: $showTutorial) {
            ediscoveryTutorialSheet
        }
        .sheet(isPresented: $showPIIReport) {
            PIIReportView(presetEmails: emails,
                          onClose: { showPIIReport = false })
        }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "ediscovery_tutorial_seen") {
                showTutorial = true
                UserDefaults.standard.set(true, forKey: "ediscovery_tutorial_seen")
            }
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

            Button {
                showTutorial = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .imageScale(.large)
                    .foregroundColor(AppColors.primary)
            }
            .buttonStyle(.plain)
            .help("How to use E-Discovery")
            .accessibilityLabel("Show e-discovery tutorial")

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
            .help("Export or print the summary, or reset the workflow")
            .accessibilityLabel("Workflow options menu")

            Button {
                closeSheet()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help("Close — progress is kept")
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
                        .accessibilityHint(isCurrent ? String(localized: "Currently selected phase") : String(localized: "Tap to select this phase"))

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
                        Text(LocalizedStringKey(status.rawValue))
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

                // Inline guidance hint
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(AppColors.primary)
                        .font(.system(size: 12))
                    Text(phaseGuidanceHint(for: phase))
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.primary)
                }
                .padding(Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))

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
            if v3 {
                WholeScopeNote()
                if v3Running { ProgressView().controlSize(.small) }
            }

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
            HStack {
                Text("Custodians: \(manager.caseInfo.custodians.isEmpty ? "All (none specified)" : manager.caseInfo.custodians.joined(separator: ", "))")
                    .font(Typography.callout)
                Spacer()
            }
            if manager.caseInfo.dateRangeStart != nil || manager.caseInfo.dateRangeEnd != nil {
                HStack {
                    let fmt = { () -> DateFormatter in let f = DateFormatter(); f.dateStyle = .medium; return f }()
                    let start = manager.caseInfo.dateRangeStart.map { fmt.string(from: $0) } ?? "Any"
                    let end = manager.caseInfo.dateRangeEnd.map { fmt.string(from: $0) } ?? "Any"
                    Text("Date range: \(start) – \(end)")
                        .font(Typography.callout)
                    Spacer()
                }
            }

            if let results = identificationResults {
                Divider()
                HStack(spacing: Spacing.medium) {
                    VStack {
                        Text("\(results.matching)")
                            .font(Typography.title3).fontWeight(.bold)
                            .foregroundColor(results.matching > 0 ? AppColors.success : AppColors.warning)
                        Text("Matching").font(Typography.caption2)
                    }
                    VStack {
                        Text("\(results.total)")
                            .font(Typography.title3).fontWeight(.bold)
                        Text("Total").font(Typography.caption2)
                    }
                    VStack {
                        Text("\(results.topDomains.count)")
                            .font(Typography.title3).fontWeight(.bold)
                        Text("Domains").font(Typography.caption2)
                    }
                }

                if !results.topDomains.isEmpty {
                    Text("Top domains in results:")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    ForEach(Array(results.topDomains.prefix(5).enumerated()), id: \.offset) { _, pair in
                        HStack {
                            Text(pair.0).font(Typography.caption1)
                            Spacer()
                            Text("\(pair.1) emails").font(Typography.caption1).fontWeight(.semibold)
                        }
                    }
                }

                Label {
                    Text("Searched \(results.total) emails using your custodian and date filters. \(results.matching) emails match your criteria across \(results.topDomains.count) unique domain(s). Refine filters to narrow or broaden your identification scope.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundColor(.blue)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(CornerRadius.small)
            }

            Button {
                runIdentificationSearch()
            } label: {
                Label(identificationResults == nil ? String(localized: "Run Search") : String(localized: "Re-Run Search"), systemImage: "magnifyingglass")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Run search across the emails in this collection with current criteria")
        }
    }

    private var holdCount: Int {
        if v3, let v3HeldCount { return v3HeldCount }
        return emails.filter { CustodianManager.shared.isUnderLegalHold($0.id) }.count
    }

    /// In 3.0 the comparisons below are against the whole scope.
    private var scopeCount: Int { v3 ? (scope.total ?? emails.count) : emails.count }

    private var preservationActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            if holdCount > 0 {
                Label {
                    Text("\(holdCount) of \(scopeCount) emails are under legal hold — evidence seals active. Held emails are protected from modification or deletion.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(AppColors.success)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.success.opacity(0.1))
                .cornerRadius(CornerRadius.small)
            } else {
                Text("Applying a legal hold logs the action in the forensic audit trail and locks source integrity hashes.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }

            HStack(spacing: Spacing.small) {
                if holdCount < scopeCount {
                    Button {
                        if v3 { confirmApplyHold(); return }
                        applyHoldPreviousEngine()
                    } label: {
                        Label("Apply Legal Hold", systemImage: "lock.shield")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityLabel("Apply legal hold to the \(emails.count) emails in this collection")
                    .accessibilityHint("Places legal hold with cryptographic evidence seals and stores integrity hashes")
                }

                if holdCount > 0 {
                    Button {
                        showingReleaseConfirmation = true
                    } label: {
                        Label("Release Legal Hold", systemImage: "lock.open")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Release legal hold from the emails in this collection")
                }
            }
        }
    }

    private var collectionActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let sourceFiles = Set(emails.compactMap { $0.headers["sourceFile"] })
            Text("Currently loaded: \(emails.count) email(s) from \(max(1, sourceFiles.count)) source(s).")
                .font(Typography.callout)

            if !sourceFiles.isEmpty {
                ForEach(Array(sourceFiles.sorted().enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.zipper")
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.secondary)
                        Text(file).font(Typography.caption1).lineLimit(1)
                    }
                }
            }

            if let verification = collectionVerification {
                Divider()
                Text("Integrity Verification")
                    .font(Typography.caption1).fontWeight(.semibold)
                HStack(spacing: Spacing.medium) {
                    VStack {
                        Text("\(verification.passed)")
                            .font(Typography.title3).fontWeight(.bold)
                            .foregroundColor(AppColors.success)
                        Text("Verified").font(Typography.caption2)
                    }
                    VStack {
                        Text("\(verification.failed)")
                            .font(Typography.title3).fontWeight(.bold)
                            .foregroundColor(verification.failed > 0 ? .red : AppColors.secondary)
                        Text("Failed").font(Typography.caption2)
                    }
                    VStack {
                        Text("\(verification.unverified)")
                            .font(Typography.title3).fontWeight(.bold)
                            .foregroundColor(AppColors.info)
                        Text("Newly Sealed").font(Typography.caption2)
                    }
                }
                if verification.failed > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("\(verification.failed) email(s) failed integrity check — possible tampering detected")
                            .font(Typography.caption1).foregroundColor(.red)
                    }
                }

                if verification.failed > 0 {
                    Label {
                        Text("\(verification.failed) email(s) failed SHA-256 hash verification — content may have been modified since import. Investigate these emails before proceeding.")
                            .font(Typography.caption1)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(AppColors.error)
                    }
                    .padding(Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.error.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                } else if verification.unverified > 0 {
                    Label {
                        Text("SHA-256 hashes computed and sealed for \(verification.unverified) email(s). \(verification.passed) previously sealed email(s) verified intact. Run again to confirm all baselines.")
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
                        Text("All \(verification.passed) emails verified — SHA-256 hashes match sealed originals. Collection integrity confirmed for e-discovery production.")
                            .font(Typography.caption1)
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(AppColors.success)
                    }
                    .padding(Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.success.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                }
            }

            if isVerifyingCollection {
                ProgressView("Computing SHA-256 hashes and verifying integrity...")
                    .font(Typography.caption1)
            }

            Button {
                verifyCollection()
            } label: {
                Label(collectionVerification == nil ? String(localized: "Verify & Seal Collection") : String(localized: "Re-Verify Collection"), systemImage: "checkmark.shield")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isVerifyingCollection)
            .accessibilityLabel("Compute cryptographic hashes and verify email collection integrity")
        }
    }

    private var processingActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let categories = (nlpCategories ?? []).map { (key: $0.category, value: $0.count) }

            if !categories.isEmpty {
                Text("Classification of \(emails.count) emails:")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                ForEach(categories, id: \.key) { category, count in
                    HStack {
                        Text(LocalizedStringKey(category.rawValue))
                            .font(Typography.callout)
                        Spacer()
                        Text("\(count)")
                            .font(Typography.callout)
                            .fontWeight(.semibold)
                    }
                }
            }

            Button {
                runNLPAnalysis()
            } label: {
                Label(isRunningNLP ? String(localized: "Analyzing…")
                      : nlpCategories == nil ? String(localized: "Run NLP Analysis") : String(localized: "Re-run NLP Analysis"),
                      systemImage: "brain")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isRunningNLP || emails.isEmpty)
            .accessibilityLabel("Run NLP classification on the emails in this collection")

            Button {
                showPIIReport = true
            } label: {
                Label("Scan for PII", systemImage: "person.text.rectangle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Detect SSNs, credit cards, phone numbers and other personal data in this collection — with a CSV report for privilege review")
            .accessibilityLabel("Scan collection for personally identifiable information")

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
            let taggedCount = ForensicManager.shared.evidenceTags.values.filter { $0 != .none }.count
            Text("Tagged emails: \(taggedCount)")
                .font(Typography.callout)
            Text("Annotated emails: \(ForensicManager.shared.annotations.count)")
                .font(Typography.callout)

            if let batches = reviewBatches {
                Divider()
                Text("Review Batches by Category")
                    .font(Typography.caption1).fontWeight(.semibold)
                ForEach(Array(batches.enumerated()), id: \.offset) { _, batch in
                    HStack {
                        Text(batch.category).font(Typography.callout)
                        Spacer()
                        Text("\(batch.count) emails")
                            .font(Typography.callout).fontWeight(.semibold)
                    }
                }

                if privilegeScanCount > 0 {
                    Divider()
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(.orange)
                        Text("\(privilegeScanCount) email(s) flagged as potentially privileged — review before production")
                            .font(Typography.caption1).foregroundColor(.orange)
                    }
                }

                Label {
                    Text("Emails classified using NLP into review categories. Each batch groups similar emails for efficient reviewer assignment. Privilege-flagged items require attorney review before production.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(CornerRadius.small)

                let stats = ForensicManager.shared.computeReviewerStats()
                if stats.totalTagged > 0 {
                    Divider()
                    Text("Reviewer Progress")
                        .font(Typography.caption1).fontWeight(.semibold)
                    HStack(spacing: Spacing.medium) {
                        VStack {
                            Text("\(stats.totalTagged)")
                                .font(Typography.title3).fontWeight(.bold)
                            Text("Tagged").font(Typography.caption2)
                        }
                        VStack {
                            Text("\(stats.privilegeFlagged)")
                                .font(Typography.title3).fontWeight(.bold)
                                .foregroundColor(stats.privilegeFlagged > 0 ? .orange : AppColors.secondary)
                            Text("Privileged").font(Typography.caption2)
                        }
                        if stats.avgSecondsPerTag > 0 {
                            VStack {
                                Text(String(format: "%.0fs", stats.avgSecondsPerTag))
                                    .font(Typography.title3).fontWeight(.bold)
                                Text("Avg/Tag").font(Typography.caption2)
                            }
                        }
                    }
                }
            }

            Button {
                createReviewBatches()
            } label: {
                Label(reviewBatches == nil ? String(localized: "Create Review Batches") : String(localized: "Refresh Batches"), systemImage: "rectangle.stack.badge.play")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Create review batches using NLP classification and privilege scanning")
        }
    }

    private var productionActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Generate production deliverables for the current email set.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            HStack(spacing: Spacing.small) {
                Button {
                    if v3 { v3Export(.loadFile); return }
                    let dat = ForensicManager.shared.exportConcordanceDAT(emails: emails)
                    let outcome = PlatformExport.save(text: dat, suggestedName: "production_loadfile.dat")
                    if let url = outcome.url {
                        ForensicManager.shared.logAction(
                            "E-Discovery: Load File Generated",
                            detail: "Concordance DAT load file for \(emails.count) emails → \(url.lastPathComponent)"
                        )
                        let n = emails.count
                        Task { await DocumentRegistry.post(.export, summary: "Concordance load file — \(n) emails", refs: url.lastPathComponent) }
                    }
                    showActionMessage(outcome.message(String(localized: "Load file")))
                } label: {
                    Label("Generate Load File", systemImage: "doc.text")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Generate Concordance DAT load file")

                Button {
                    if v3 { v3Export(.productionCSV); return }
                    let csv = ForensicManager.shared.exportBulkForensicCSV(emails: emails)
                    let outcome = PlatformExport.save(text: csv, suggestedName: "production_export.csv")
                    if let url = outcome.url {
                        ForensicManager.shared.logAction(
                            "E-Discovery: Production Export",
                            detail: "Production CSV exported for \(emails.count) emails → \(url.lastPathComponent)"
                        )
                        let n = emails.count
                        Task { await DocumentRegistry.post(.export, summary: "Production CSV — \(n) emails", refs: url.lastPathComponent) }
                    }
                    showActionMessage(outcome.message(String(localized: "Production CSV")))
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Export production CSV")

                Button {
                    if v3 { v3Export(.privilegeLog); return }
                    let log = ForensicManager.shared.exportPrivilegeLog(emails: emails)
                    if log.isEmpty {
                        showActionMessage("No privileged emails tagged — tag emails first")
                    } else {
                        let outcome = PlatformExport.save(text: log, suggestedName: "privilege_log.csv")
                        if let url = outcome.url {
                            ForensicManager.shared.logAction(
                                "E-Discovery: Privilege Log",
                                detail: "Privilege log generated for \(emails.count) emails → \(url.lastPathComponent)"
                            )
                            Task { await DocumentRegistry.post(.export, summary: "Privilege log", refs: url.lastPathComponent) }
                        }
                        showActionMessage(outcome.message(String(localized: "Privilege log")))
                    }
                } label: {
                    Label("Privilege Log", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Generate privilege log")
            }
            // §3-E2: the production's evidence record — a hash-tree proof per
            // email to the archive fingerprint — saved alongside, one tap.
            if productionRecordOffered {
                Button(String(localized: "Save evidence record for this production")) {
                    Task { @MainActor in
                        let (outcome, n) = await EvidenceRecordExporter.export(scope: scope)
                        showActionMessage(outcome.message(String(localized: "Evidence record")) + (outcome.succeeded ? " (\(n))" : ""))
                        if case .cancelled = outcome {} else { productionRecordOffered = false }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Every produced email with a hash-tree proof to the archive fingerprint — verifiable with SHA-256 alone")
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

    // MARK: - Identification Search

    /// `previousEngine`: the pre-3.0 path (switch off, or §3-M3 fallback).
    private func runIdentificationSearch(previousEngine: Bool = false) {
        manager.startPhase(.identification)
        if v3 && !previousEngine {
            let info = manager.caseInfo
            runV3(previous: { runIdentificationSearch(previousEngine: true) }) {
                let r = try await EDiscoveryEngine.identify(scope: scope, custodians: info.custodians,
                                                            start: info.dateRangeStart, end: info.dateRangeEnd)
                identificationResults = (matching: r.matching, total: r.total, topDomains: r.topDomains)
                ForensicManager.shared.logAction(
                    "E-Discovery: Identification Search",
                    detail: "Found \(r.matching)/\(r.total) emails matching criteria for case \(info.caseNumber) — \(r.receipt.coverageLine)")
                await ScopeJob.recordReceipt(r.receipt, registry: modules)
                showActionMessage(String(localized: "Found \(r.matching) of \(r.total) emails matching criteria"))
            }
            return
        }

        var filtered = emails

        if !manager.caseInfo.custodians.isEmpty {
            let custodianLower = manager.caseInfo.custodians.map { $0.lowercased() }
            filtered = filtered.filter { email in
                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                return custodianLower.contains(where: { from.contains($0) || to.contains($0) })
            }
        }

        if let startDate = manager.caseInfo.dateRangeStart {
            filtered = filtered.filter { email in
                guard let dateStr = email.headers["Date"],
                      let emailDate = MBOXParser.parseDate(dateStr) else { return true }
                return emailDate >= startDate
            }
        }
        if let endDate = manager.caseInfo.dateRangeEnd {
            filtered = filtered.filter { email in
                guard let dateStr = email.headers["Date"],
                      let emailDate = MBOXParser.parseDate(dateStr) else { return true }
                return emailDate <= endDate
            }
        }

        var domainCounts: [String: Int] = [:]
        for email in filtered {
            for domain in email.domains {
                domainCounts[domain, default: 0] += 1
            }
        }
        let topDomains = domainCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }

        identificationResults = (matching: filtered.count, total: emails.count, topDomains: topDomains)

        ForensicManager.shared.logAction(
            "E-Discovery: Identification Search",
            detail: "Found \(filtered.count)/\(emails.count) emails matching criteria for case \(manager.caseInfo.caseNumber)"
        )
        showActionMessage("Found \(filtered.count) of \(emails.count) emails matching criteria")
    }

    // MARK: - Collection Verification

    /// `previousEngine`: the pre-3.0 path (switch off, or §3-M3 fallback).
    private func verifyCollection(previousEngine: Bool = false) {
        if v3 && !previousEngine {
            isVerifyingCollection = true
            runV3(previous: { verifyCollection(previousEngine: true) }) {
                defer { isVerifyingCollection = false }
                let (state, receipt) = try await EDiscoveryEngine.verifyCollection(
                    scope: scope, useFingerprints: modules?.isOn(.v3Fingerprints) ?? false)
                collectionVerification = (passed: state.passed, failed: state.failed, unverified: state.newlySealed)
                await ScopeJob.recordReceipt(receipt, extra: state.failedIDs.prefix(500).map {
                    .init(key: String(localized: "Failed"), value: $0.uuidString)
                }, registry: modules)
                showActionMessage(String(localized: "Collection verified: \(state.passed) passed, \(state.failed) failed, \(state.newlySealed) newly sealed"))
            }
            return
        }
        isVerifyingCollection = true
        let collection = emails
        Task { @MainActor in
            let forensic = ForensicManager.shared
            // Verify against the ORIGINAL stored seals before sealing anything.
            // Sealing first made every email outside the in-memory window
            // verify against its own current content — a tampered email passed.
            await forensic.prefetchForensicWindow(ids: collection.map(\.id))
            let result = forensic.batchVerifyAllEmails(collection)
            // Emails with no seal at all get their first (baseline) seal now.
            let unsealed = collection.filter { forensic.perEmailHashes[$0.id] == nil }
            if !unsealed.isEmpty { forensic.storeEmailHashes(unsealed) }
            collectionVerification = (passed: result.passed, failed: result.failed, unverified: result.unverified)

            let sourceFiles = Set(collection.compactMap { $0.headers["sourceFile"] }).count
            forensic.logAction(
                "E-Discovery: Collection Verified",
                detail: "Collection of \(collection.count) emails from \(max(1, sourceFiles)) source(s): \(result.passed) verified, \(result.failed) failed, \(result.unverified) newly sealed"
            )
            isVerifyingCollection = false
            showActionMessage("Collection verified: \(result.passed) passed, \(result.failed) failed, \(result.unverified) newly sealed")
        }
    }

    // MARK: - NLP Analysis

    /// Classifies every email in the collection off the main thread, shows
    /// the counts, and records them as a numbered document — the audit entry
    /// is written only after the analysis has actually run.
    /// `previousEngine`: the pre-3.0 path (switch off, or §3-M3 fallback).
    private func runNLPAnalysis(previousEngine: Bool = false) {
        if v3 && !previousEngine {
            isRunningNLP = true
            runV3(previous: { runNLPAnalysis(previousEngine: true) }) {
                defer { isRunningNLP = false }
                let (sorted, receipt) = try await EDiscoveryEngine.classify(scope: scope)
                nlpCategories = sorted
                ForensicManager.shared.logAction("E-Discovery: NLP Analysis",
                    detail: "Classified \(receipt.processed) emails into \(sorted.count) categories — \(receipt.coverageLine)")
                await DocumentRegistry.captureStructured(
                    .report, summary: "E-Discovery NLP classification — \(receipt.processed) emails",
                    document: CapturedDocument(title: String(localized: "NLP Classification"), sections: [
                        .init(name: String(localized: "Categories"), fields: sorted.map {
                            .init(key: $0.category.rawValue, value: String($0.count))
                        }),
                        .init(name: String(localized: "Job receipt"), fields: receipt.documentFields)]))
                showActionMessage(String(localized: "NLP analysis complete — \(receipt.processed) emails in \(sorted.count) categories"))
            }
            return
        }
        isRunningNLP = true
        let collection = emails
        Task { @MainActor in
            let counts = await Task.detached(priority: .userInitiated) {
                EmailNLPEngine.classifyAll(collection)
            }.value
            let sorted = counts.sorted { $0.value > $1.value }.map { (category: $0.key, count: $0.value) }
            nlpCategories = sorted
            isRunningNLP = false
            ForensicManager.shared.logAction(
                "E-Discovery: NLP Analysis",
                detail: "Classified \(collection.count) emails into \(sorted.count) categories")
            await DocumentRegistry.captureStructured(
                .report, summary: "E-Discovery NLP classification — \(collection.count) emails",
                document: CapturedDocument(title: String(localized: "NLP Classification"), sections: [
                    .init(name: String(localized: "Categories"), fields: sorted.map {
                        .init(key: $0.category.rawValue, value: String($0.count))
                    })]))
            showActionMessage("NLP analysis complete — \(collection.count) emails in \(sorted.count) categories")
        }
    }

    // MARK: - Review Batches

    /// Creates real review batches (Review Batches panel) — privilege-flagged
    /// emails first, then grouped by category — instead of only a count list.
    /// Existing batches with review progress are never overwritten.
    /// `previousEngine`: the pre-3.0 path (switch off, or §3-M3 fallback).
    private func createReviewBatches(previousEngine: Bool = false) {
        let batchManager = ReviewBatchManager.shared
        let reviewedSoFar = batchManager.batches.reduce(0) { $0 + $1.reviewedIDs.count }
        if reviewedSoFar > 0 {
            showActionMessage("Review batches already exist with \(reviewedSoFar) emails reviewed — reset them in Review Batches before creating new ones")
            return
        }
        if v3 && !previousEngine {
            runV3(previous: { createReviewBatches(previousEngine: true) }) {
                let r = try await EDiscoveryEngine.createReviewBatches(scope: scope)
                privilegeScanCount = r.privileged
                reviewBatches = r.categories
                await ScopeJob.recordReceipt(r.receipt, registry: modules)
                showActionMessage(String(localized: "Created \(r.batches) review batches (\(r.privileged) privilege-flagged first) — open Review Batches to start"))
            }
            return
        }
        let forensic = ForensicManager.shared
        forensic.runPrivilegeScan(on: emails)
        privilegeScanCount = forensic.privilegeFlags.count

        var categoryOf: [UUID: EmailNLPEngine.EmailCategory] = [:]
        for email in emails { categoryOf[email.id] = EmailNLPEngine.classify(email) }
        var counts: [EmailNLPEngine.EmailCategory: Int] = [:]
        for c in categoryOf.values { counts[c, default: 0] += 1 }
        let order = counts.sorted { $0.value > $1.value }.map(\.key)
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let ordered = emails.map(\.id).sorted { a, b in
            let pa = forensic.privilegeFlags[a] != nil, pb = forensic.privilegeFlags[b] != nil
            if pa != pb { return pa }
            return (categoryOf[a].flatMap { rank[$0] } ?? 0) < (categoryOf[b].flatMap { rank[$0] } ?? 0)
        }
        batchManager.createBatches(from: ordered, batchSize: 50, namePrefix: "Review")
        reviewBatches = order.map { (category: $0.rawValue, count: counts[$0] ?? 0) }

        let stats = forensic.computeReviewerStats()
        forensic.logAction(
            "E-Discovery: Review Batches Created",
            detail: "\(batchManager.batches.count) batches of up to 50 from \(emails.count) emails (privilege-flagged first, then by category). \(privilegeScanCount) privilege-flagged. \(stats.totalTagged) previously tagged."
        )
        showActionMessage("Created \(batchManager.batches.count) review batches (\(privilegeScanCount) privilege-flagged first) — open Review Batches to start")
    }

    // MARK: - 3.0 whole-scope helpers

    /// Runs a whole-scope action; errors are shown, never swallowed. With
    /// `previous`, a 3.0 engine that throws falls back to the previous engine
    /// for this call (§3-M3) and the result message says so.
    private func runV3(previous: (@MainActor () -> Void)? = nil,
                       _ body: @escaping @MainActor () async throws -> Void) {
        guard !v3Running else { return }
        v3Running = true
        Task { @MainActor in
            defer { v3Running = false }
            do {
                try await body()
            } catch is CancellationError {
            } catch {
                if let previous {
                    fallbackPrefix = EngineGuard.fellBack(.v3EDiscovery, error: error)
                    previous()
                } else {
                    showActionMessage(error.localizedDescription)
                }
            }
        }
    }

    /// The pre-3.0 hold: the loaded collection (switch off, or §3-M3 fallback).
    private func applyHoldPreviousEngine() {
        let collection = emails
        Task { @MainActor in
            CustodianManager.shared.placeLegalHold(on: collection)
            // Load stored seals first so existing originals are kept,
            // not replaced in memory by the current content.
            await ForensicManager.shared.prefetchForensicWindow(ids: collection.map(\.id))
            ForensicManager.shared.storeEmailHashes(collection)
            showActionMessage("Legal hold applied with evidence seals — \(collection.count) emails protected")
        }
    }

    private func confirmApplyHold() {
        Task { @MainActor in
            scopeConfirm = await ScopeConfirm.request(
                scope, title: String(localized: "Apply Legal Hold"), verb: String(localized: "Apply Hold"),
                detail: String(localized: "Each email is sealed with its current content the first time it is held. Existing seals are never replaced.")
            ) {
                runV3(previous: { applyHoldPreviousEngine() }) {
                    let r = try await EDiscoveryEngine.applyHold(scope: scope)
                    v3HeldCount = await EDiscoveryEngine.heldCount(scope: scope)
                    await ScopeJob.recordReceipt(r.receipt, registry: modules)
                    showActionMessage(String(localized: "Legal hold applied — \(r.held) emails newly held, \(r.sealed) newly sealed. \(r.receipt.coverageLine)"))
                }
            }
        }
    }

    private enum V3Export { case loadFile, productionCSV, privilegeLog }

    private func v3Export(_ kind: V3Export) {
        runV3 {
            let forensic = ForensicManager.shared
            switch kind {
            case .loadFile:
                let (outcome, result) = (modules?.isOn(.v3FeatureIndex) ?? false)
                    ? await EDiscoveryEngine.exportLoadFileWithMIH(scope: scope)
                    : await EDiscoveryEngine.exportLoadFile(scope: scope)
                if let url = outcome.url, let result {
                    forensic.logAction("E-Discovery: Load File Generated",
                                       detail: "Concordance DAT load file for \(result.recordsWritten) emails → \(url.lastPathComponent)")
                    _ = await DocumentRegistry.post(.export, summary: "Concordance load file — \(result.recordsWritten) emails", refs: url.lastPathComponent)
                }
                if outcome.succeeded, modules?.isOn(.v3Fingerprints) ?? false { productionRecordOffered = true }
                showActionMessage(outcome.message(String(localized: "Load file")))
            case .productionCSV:
                let (outcome, result) = await EDiscoveryEngine.exportProductionCSV(scope: scope)
                if let url = outcome.url, let result {
                    forensic.logAction("E-Discovery: Production Export",
                                       detail: "Production CSV exported for \(result.recordsWritten) emails → \(url.lastPathComponent)")
                    _ = await DocumentRegistry.post(.export, summary: "Production CSV — \(result.recordsWritten) emails", refs: url.lastPathComponent)
                }
                if outcome.succeeded, modules?.isOn(.v3Fingerprints) ?? false { productionRecordOffered = true }
                showActionMessage(outcome.message(String(localized: "Production CSV")))
            case .privilegeLog:
                let (outcome, n) = await EDiscoveryEngine.exportPrivilegeLog(scope: scope)
                if let url = outcome.url {
                    forensic.logAction("E-Discovery: Privilege Log",
                                       detail: "Privilege log of \(n) privileged emails → \(url.lastPathComponent)")
                    _ = await DocumentRegistry.post(.export, summary: "Privilege log — \(n) emails", refs: url.lastPathComponent)
                }
                showActionMessage(outcome.message(String(localized: "Privilege log")))
            }
        }
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

    // MARK: - Phase Guidance

    private func phaseGuidanceHint(for phase: EDiscoveryPhase) -> String {
        switch phase {
        case .identification:
            return "Set custodians & date range above, then click \"Run Search\" to find matching emails."
        case .preservation:
            return "Click \"Apply Legal Hold\" to seal evidence with SHA-256 hashes and start chain of custody."
        case .collection:
            return "Click \"Verify & Seal Collection\" to confirm email integrity with cryptographic hashes."
        case .processing:
            return "Click \"Run NLP Analysis\" to classify emails by category. Use \"Enhance with AI\" for deeper insights."
        case .review:
            return "Click \"Create Review Batches\" to group emails by category and scan for privileged materials."
        case .production:
            return String(localized: "Generate a Load File (DAT), Export (CSV), or Privilege Log to produce deliverables.")
        }
    }

    // MARK: - Tutorial Sheet

    private var ediscoveryTutorialSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 20))
                    .foregroundColor(AppColors.primary)
                Text("How to Use E-Discovery")
                    .font(Typography.title2)
                Spacer()
                Button {
                    showTutorial = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close the tutorial")
                .accessibilityLabel("Close tutorial")
            }
            .padding(Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    // Overview
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        Label("What is E-Discovery?", systemImage: "info.circle.fill")
                            .font(Typography.headline)
                            .foregroundColor(AppColors.primary)
                        Text("E-Discovery (Electronic Discovery) is the legal process of identifying, preserving, collecting, processing, reviewing, and producing electronically stored information (ESI) for legal proceedings. This workflow follows the EDRM (Electronic Discovery Reference Model) standard used by legal professionals worldwide.")
                            .font(Typography.body)
                            .foregroundColor(AppColors.secondary)
                    }
                    .padding(Spacing.medium)
                    .adaptiveCard(cornerRadius: CornerRadius.medium)

                    // Quick Start
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        Label("Quick Start", systemImage: "bolt.fill")
                            .font(Typography.headline)
                            .foregroundColor(.orange)
                        Text("Work through the 6 phases in order from left to right. Click each phase circle in the stepper bar to navigate. Complete the checklist, run the action, then click \"Mark Complete\" to advance.")
                            .font(Typography.body)
                            .foregroundColor(AppColors.secondary)
                    }
                    .padding(Spacing.medium)
                    .adaptiveCard(cornerRadius: CornerRadius.medium)

                    // Phase Guide
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        Label("The 6 Phases", systemImage: "list.number")
                            .font(Typography.headline)
                            .foregroundColor(AppColors.primary)

                        tutorialPhaseRow(
                            number: "1",
                            title: String(localized: "Identification"),
                            icon: "magnifyingglass",
                            color: .blue,
                            what: String(localized: "Define who and what you're looking for."),
                            how: "Set custodians and date ranges in Case Info (top of workflow), then click \"Run Search\". The search filters your emails by those criteria and shows matching results with domain breakdown.",
                            tip: "Leave custodians empty to search all emails. Add names or email addresses to narrow scope."
                        )

                        tutorialPhaseRow(
                            number: "2",
                            title: String(localized: "Preservation"),
                            icon: "lock.shield",
                            color: .green,
                            what: String(localized: "Lock evidence to prevent tampering."),
                            how: "Click \"Apply Legal Hold\". This computes SHA-256 cryptographic hashes for every email and stores them in the forensic audit trail. Any future changes will be detected.",
                            tip: "This creates a tamper-evident chain of custody — required for court admissibility."
                        )

                        tutorialPhaseRow(
                            number: "3",
                            title: String(localized: "Collection"),
                            icon: "tray.and.arrow.down",
                            color: .purple,
                            what: String(localized: "Verify the integrity of imported emails."),
                            how: "Click \"Verify & Seal Collection\". This computes SHA-256 hashes for all emails and verifies them against stored values. Shows how many passed, failed, or are newly sealed.",
                            tip: "If any emails show \"Failed\" — that means the content changed since preservation. Investigate immediately."
                        )

                        tutorialPhaseRow(
                            number: "4",
                            title: String(localized: "Processing"),
                            icon: "gearshape.2",
                            color: .orange,
                            what: String(localized: "Classify and analyze email content."),
                            how: "Click \"Run NLP Analysis\". The NLP engine classifies emails into categories (personal, transactional, newsletter, etc.) and shows the breakdown. Optionally click \"Enhance with AI\" for deeper insights on macOS 26+.",
                            tip: "The classification preview updates automatically — use it to understand your data before review."
                        )

                        tutorialPhaseRow(
                            number: "5",
                            title: String(localized: "Review"),
                            icon: "doc.text.magnifyingglass",
                            color: .red,
                            what: String(localized: "Review documents and flag privileged materials."),
                            how: "Click \"Create Review Batches\". This groups emails by NLP category and runs a privilege scan to flag potentially privileged communications (attorney-client, work product). Review flagged emails before production.",
                            tip: "Use the Forensic Review or Legal Review tools from the sidebar to tag individual emails as relevant, privileged, or irrelevant."
                        )

                        tutorialPhaseRow(
                            number: "6",
                            title: String(localized: "Production"),
                            icon: "shippingbox",
                            color: .teal,
                            what: String(localized: "Export deliverables for opposing counsel or court."),
                            how: "Three export options:\n• Generate Load File — Concordance DAT format (industry standard)\n• Export — Full production CSV with all metadata\n• Privilege Log — List of withheld privileged documents with reasons",
                            tip: "Apply Bates numbering first (check the checklist item) for sequential document identification."
                        )
                    }
                    .padding(Spacing.medium)
                    .adaptiveCard(cornerRadius: CornerRadius.medium)

                    // Tips
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        Label("Tips", systemImage: "lightbulb.fill")
                            .font(Typography.headline)
                            .foregroundColor(.yellow)

                        tutorialTipRow(icon: "checkmark.square", text: "Checklists are for your own tracking — tick items as you complete them manually.")
                        tutorialTipRow(icon: "note.text", text: "Use the Notes section in each phase to document decisions and rationale.")
                        tutorialTipRow(icon: "arrow.right.circle", text: "You can skip phases that don't apply — click \"Skip Phase\" at the bottom.")
                        tutorialTipRow(icon: "arrow.counterclockwise", text: "Use the ••• menu to reset the entire workflow or export a summary report.")
                        tutorialTipRow(icon: "questionmark.circle", text: "Click the ? button anytime to reopen this guide.")
                    }
                    .padding(Spacing.medium)
                    .adaptiveCard(cornerRadius: CornerRadius.medium)
                }
                .padding(Spacing.medium)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button {
                    showTutorial = false
                } label: {
                    Text("Got It — Start Working")
                        .fontWeight(.semibold)
                }
                .buttonStyle(PrimaryButtonStyle())
                Spacer()
            }
            .padding(Spacing.medium)
        }
        .background(AppColors.backgroundPrimary)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 740,
               minHeight: 480, idealHeight: 620, maxHeight: 800)
        #endif
    }

    private func tutorialPhaseRow(number: String, title: String, icon: String, color: Color, what: String, how: String, tip: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(color)
                }
                Text("Phase \(number): \(title)")
                    .font(Typography.callout)
                    .fontWeight(.semibold)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(what)
                    .font(Typography.body)
                    .fontWeight(.medium)
                Text(how)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "lightbulb.min")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                    Text(tip)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .italic()
                }
                .padding(.top, 2)
            }
            .padding(.leading, 36)
        }
    }

    private func tutorialTipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.xSmall) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(AppColors.primary)
                .frame(width: 16)
            Text(text)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
    }

    // MARK: - Helpers

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private func exportSummary() {
        let summary = manager.exportWorkflowSummary()
        let outcome = PlatformExport.save(text: summary, suggestedName: "ediscovery_workflow_\(manager.caseInfo.caseNumber).txt")
        showActionMessage(outcome.message(String(localized: "Summary")))
    }

    private func printSummary() {
        let summary = manager.exportWorkflowSummary()
        PlatformPrinter.printText(summary)
    }

    private func showActionMessage(_ message: String) {
        // §3-M3: the message that follows a fallback says so.
        let text = fallbackPrefix.map { $0 + " " + message } ?? message
        fallbackPrefix = nil
        withAnimation(AnimationTiming.fast) {
            actionMessage = text
        }
        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3000000000)
            withAnimation(AnimationTiming.fast) {
                actionMessage = nil
            }
        }
    }
}
