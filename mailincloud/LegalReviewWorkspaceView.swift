import SwiftUI

struct LegalReviewWorkspaceView: View {
    let emails: [MBOXParser.RawEmail]
    @Binding var selectedEmailIDs: Set<UUID>

    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var reviewManager = ForensicReviewManager.shared
    @ObservedObject private var batesManager = BatesNumberingManager.shared
    @ObservedObject private var custodianManager = CustodianManager.shared

    // MARK: - Privilege Designation

    enum PrivilegeDesignation: String, CaseIterable, Identifiable {
        case unreviewed = "Unreviewed"
        case attorneyClient = "Attorney-Client"
        case workProduct = "Work Product"
        case jointDefense = "Joint Defense"
        case notPrivileged = "Not Privileged"
        case partiallyPrivileged = "Partially Privileged"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .unreviewed: return "circle"
            case .attorneyClient: return "lock.shield.fill"
            case .workProduct: return "doc.text.fill"
            case .jointDefense: return "person.2.fill"
            case .notPrivileged: return "checkmark.circle"
            case .partiallyPrivileged: return "circle.lefthalf.filled"
            }
        }

        var color: Color {
            switch self {
            case .unreviewed: return .secondary
            case .attorneyClient: return .orange
            case .workProduct: return .blue
            case .jointDefense: return .purple
            case .notPrivileged: return .green
            case .partiallyPrivileged: return .yellow
            }
        }

        var shortKey: String {
            switch self {
            case .unreviewed: return "0"
            case .attorneyClient: return "1"
            case .workProduct: return "2"
            case .jointDefense: return "3"
            case .notPrivileged: return "4"
            case .partiallyPrivileged: return "5"
            }
        }
    }

    enum ResponsivenessTag: String, CaseIterable, Identifiable {
        case unreviewed = "Unreviewed"
        case responsive = "Responsive"
        case notResponsive = "Not Responsive"
        case partiallyResponsive = "Partially Responsive"

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .unreviewed: return .secondary
            case .responsive: return .green
            case .notResponsive: return .red
            case .partiallyResponsive: return .orange
            }
        }
    }

    // MARK: - State

    @State private var privilegeAssignments: [UUID: PrivilegeDesignation] = [:]
    @State private var responsivenessAssignments: [UUID: ResponsivenessTag] = [:]
    @State private var issueTagAssignments: [UUID: Set<String>] = [:]
    @State private var legalNotes: [UUID: String] = [:]
    @State private var definedIssueTags: [String] = ["Breach of Contract", "IP Infringement", "Employment", "Regulatory", "Trade Secret", "Antitrust", "Data Privacy"]
    @State private var newIssueTag = ""

    @State private var showCodingPanel = true
    @State private var showPrivilegeLog = false
    @State private var showBulkCoding = false
    @State private var showDashboard = false

    // v2: Audit trail & AI suggestions
    @State private var auditTrail: [(date: Date, emailID: UUID, field: String, oldValue: String, newValue: String)] = []
    @State private var aiSuggestions: [UUID: PrivilegeDesignation] = [:]
    @State private var isRunningAIScan = false
    @State private var scanResultMessage: String?
    @State private var reviewStartTime: Date = Date()

    // v3: KG + NLP + Anomaly
    @State private var graph = KnowledgeGraph()
    @State private var kgLoaded = false
    @State private var piiFindings: [EmailNLPEngine.PIIFinding] = []
    @State private var entities: [EmailNLPEngine.EntityResult] = []
    @State private var anomalies: [AnomalyDetectionEngine.Anomaly] = []
    @State private var nlpTopics: [(word: String, count: Int)] = []
    @State private var hasV3Analysis = false
    @State private var isV3Loading = false

    // v4: AI + PDF + Background
    @State private var aiPrivilegeNarrative = ""
    @State private var isGeneratingPrivilege = false
    @State private var showPDFExport = false
    @ObservedObject private var backgroundManager = BackgroundAnalysisManager.shared

    // v5: LegalAnalysisFeatures integration
    @State private var privilegeClassifications: [LegalAnalysisFeatures.PrivilegeClassification] = []
    @State private var legalHoldDetections: [LegalAnalysisFeatures.LegalHoldDetection] = []
    @State private var custodianAnalyses: [LegalAnalysisFeatures.CustodianAnalysis] = []
    @State private var showCustodianPanel = false
    @StateObject private var coordinator = AnalysisCoordinator()
    @State private var showTutorial = false

    // MARK: - Filters

    @State private var filterPrivilege: PrivilegeDesignation?
    @State private var filterResponsiveness: ResponsivenessTag?
    @State private var filterIssueTag: String?
    @State private var filterSearchText = ""

    enum SortKey: String, CaseIterable {
        case privilege, responsive, from, subject, date
    }
    @State private var sortKey: SortKey = .date
    @State private var sortAscending = false
    @State private var expandedEmailID: UUID?

    private var selectedEmail: MBOXParser.RawEmail? {
        guard let id = selectedEmailIDs.first else { return nil }
        return emails.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            legalFindingsBanner
            filterBar
            Divider()
            #if os(macOS)
            HSplitView {
                if let email = selectedEmail {
                    legalInlineEmailDetail(email)
                        .frame(minWidth: 400)
                } else {
                    documentListPane
                        .frame(minWidth: 500)
                }
                if showCodingPanel, selectedEmail != nil {
                    privilegeCodingPane
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
                }
            }
            #else
            if selectedEmail != nil {
                legalInlineEmailDetail(selectedEmail!)
                    .overlay(alignment: .topLeading) {
                        Button { selectedEmailIDs.removeAll() } label: {
                            Label("Back to List", systemImage: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
            } else {
                documentListPane
            }
            #endif
            legalStatusBar
        }
        .overlay { if AnalysisCoordinator.isEnabled { AnalysisProgressOverlay(coordinator: coordinator) } }
        .featureTutorial(.legalReview, key: "legal_review_tutorial_seen", isPresented: $showTutorial)
        .sheet(isPresented: $showPrivilegeLog) { privilegeLogSheet }
        .sheet(isPresented: $showDashboard) { reviewDashboardSheet }
        .sheet(isPresented: $showPDFExport) { pdfPrivilegeReportSheet }
        .task { await loadV3Data() }
    }

    private func loadV3Data() async {
        let loaded = KnowledgeGraph.load()
        if loaded.nodeCount > 0 { graph = loaded; kgLoaded = true }

        guard !hasV3Analysis else { return }
        isV3Loading = true
        let emailsCopy = emails

        guard AnalysisCoordinator.isEnabled else {
            let pii = EmailNLPEngine.detectPII(in: emailsCopy)
            let ents = EmailNLPEngine.extractEntities(from: emailsCopy, limit: 15)
            let anom = AnomalyDetectionEngine.detectAnomalies(in: emailsCopy)
            let topics = EmailNLPEngine.extractTopics(from: emailsCopy, limit: 15)
            piiFindings = pii; entities = ents; anomalies = anom; nlpTopics = topics
            hasV3Analysis = true; isV3Loading = false
            let pc = LegalAnalysisFeatures.classifyPrivilege(emails: emailsCopy)
            legalHoldDetections = LegalAnalysisFeatures.detectLegalHolds(in: emailsCopy)
            custodianAnalyses = LegalAnalysisFeatures.analyzeCustodians(emails: emailsCopy, privilegeClassifications: pc)
            privilegeClassifications = pc; return
        }

        coordinator.begin(steps: 7, color: .indigo)

        coordinator.advance(step: 1, label: "Detecting PII...")
        guard let pii = await coordinator.runDetached({ EmailNLPEngine.detectPII(in: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 2, label: "Extracting entities...")
        guard let ents = await coordinator.runDetached({ EmailNLPEngine.extractEntities(from: emailsCopy, limit: 15) }) else { coordinator.finish(); return }

        coordinator.advance(step: 3, label: "Running anomaly detection...")
        guard let anom = await coordinator.runDetached({ AnomalyDetectionEngine.detectAnomalies(in: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 4, label: "Extracting legal topics...")
        guard let topics = await coordinator.runDetached({ EmailNLPEngine.extractTopics(from: emailsCopy, limit: 15) }) else { coordinator.finish(); return }

        piiFindings = pii; entities = ents; anomalies = anom; nlpTopics = topics
        hasV3Analysis = true; isV3Loading = false

        coordinator.advance(step: 5, label: "Classifying privilege...")
        guard let privClass = await coordinator.runDetached({ LegalAnalysisFeatures.classifyPrivilege(emails: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 6, label: "Detecting legal holds...")
        guard let holds = await coordinator.runDetached({ LegalAnalysisFeatures.detectLegalHolds(in: emailsCopy) }) else { coordinator.finish(); return }

        let privCopy = privClass
        coordinator.advance(step: 7, label: "Analyzing custodians...")
        guard let custodians = await coordinator.runDetached({ LegalAnalysisFeatures.analyzeCustodians(emails: emailsCopy, privilegeClassifications: privCopy) }) else { coordinator.finish(); return }

        privilegeClassifications = privClass
        legalHoldDetections = holds
        custodianAnalyses = custodians
        coordinator.finish()
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "building.columns").font(.system(size: 10)).foregroundColor(.indigo)
                Text("Legal Review").font(.system(size: 10, weight: .semibold)).foregroundColor(.indigo)
                Divider().frame(height: 14)

                privilegeFilterMenu
                responsivenessFilterMenu
                issueTagFilterMenu

                TextField("Search...", text: $filterSearchText)
                    .font(.system(size: 10))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                if hasActiveFilters {
                    Button("Clear") { clearFilters() }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.red)
                        .buttonStyle(.plain)
                }

                Spacer()

                Text("\(filteredEmails.count)/\(emails.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)

                Divider().frame(height: 14)

                Button { showPrivilegeLog = true } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 9))
                        Text("Privilege Log").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.indigo)
                }
                .buttonStyle(.plain)

                Button { showPDFExport = true } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "doc.text").font(.system(size: 9))
                        Text("PDF Report").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.indigo)
                }
                .buttonStyle(.plain)

                Button { showDashboard = true } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chart.bar").font(.system(size: 9))
                        Text("Dashboard").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button { showCodingPanel.toggle() } label: {
                    Image(systemName: showCodingPanel ? "sidebar.trailing" : "sidebar.right")
                        .font(.system(size: 10))
                        .foregroundColor(showCodingPanel ? .blue : .secondary)
                }
                .buttonStyle(.plain)

                TutorialHelpButton(showTutorial: $showTutorial)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(AppColors.backgroundSecondary.opacity(0.5))
    }

    private var privilegeFilterMenu: some View {
        Menu {
            Button("All") { filterPrivilege = nil }
            Divider()
            ForEach(PrivilegeDesignation.allCases) { priv in
                Button {
                    filterPrivilege = priv
                } label: {
                    HStack {
                        Label(priv.rawValue, systemImage: priv.icon)
                        if filterPrivilege == priv { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            filterChip("Privilege", active: filterPrivilege != nil,
                       detail: filterPrivilege?.rawValue)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 100)
    }

    private var responsivenessFilterMenu: some View {
        Menu {
            Button("All") { filterResponsiveness = nil }
            Divider()
            ForEach(ResponsivenessTag.allCases) { resp in
                Button {
                    filterResponsiveness = resp
                } label: {
                    HStack {
                        Text(resp.rawValue)
                        if filterResponsiveness == resp { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            filterChip("Responsive", active: filterResponsiveness != nil,
                       detail: filterResponsiveness?.rawValue)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 100)
    }

    private var issueTagFilterMenu: some View {
        Menu {
            Button("All Issues") { filterIssueTag = nil }
            Divider()
            ForEach(definedIssueTags, id: \.self) { tag in
                Button {
                    filterIssueTag = tag
                } label: {
                    HStack {
                        Text(tag)
                        if filterIssueTag == tag { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            filterChip("Issue", active: filterIssueTag != nil,
                       detail: filterIssueTag)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 90)
    }

    private func filterChip(_ title: String, active: Bool, detail: String?) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 9, weight: active ? .semibold : .regular))
            if let d = detail {
                Text(d)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(.indigo))
                    .lineLimit(1)
            }
        }
        .foregroundColor(active ? .indigo : .secondary)
    }

    private var hasActiveFilters: Bool {
        filterPrivilege != nil || filterResponsiveness != nil || filterIssueTag != nil || !filterSearchText.isEmpty
    }

    private func clearFilters() {
        filterPrivilege = nil
        filterResponsiveness = nil
        filterIssueTag = nil
        filterSearchText = ""
    }

    // MARK: - Filtered Emails

    private var filteredEmails: [MBOXParser.RawEmail] {
        var result = emails

        if let fp = filterPrivilege {
            result = result.filter { (privilegeAssignments[$0.id] ?? .unreviewed) == fp }
        }
        if let fr = filterResponsiveness {
            result = result.filter { (responsivenessAssignments[$0.id] ?? .unreviewed) == fr }
        }
        if let fi = filterIssueTag {
            result = result.filter { issueTagAssignments[$0.id]?.contains(fi) == true }
        }
        if !filterSearchText.isEmpty {
            let q = filterSearchText.lowercased()
            result = result.filter {
                ($0.headers["Subject"] ?? "").lowercased().contains(q) ||
                ($0.headers["From"] ?? "").lowercased().contains(q) ||
                ($0.headers["To"] ?? "").lowercased().contains(q) ||
                $0.plainBody.lowercased().contains(q)
            }
        }

        return result.sorted { a, b in
            let cmp: Bool
            switch sortKey {
            case .privilege:
                cmp = (privilegeAssignments[a.id]?.rawValue ?? "") < (privilegeAssignments[b.id]?.rawValue ?? "")
            case .responsive:
                cmp = (responsivenessAssignments[a.id]?.rawValue ?? "") < (responsivenessAssignments[b.id]?.rawValue ?? "")
            case .from:
                cmp = (a.headers["From"] ?? "").localizedCaseInsensitiveCompare(b.headers["From"] ?? "") == .orderedAscending
            case .subject:
                cmp = (a.headers["Subject"] ?? "").localizedCaseInsensitiveCompare(b.headers["Subject"] ?? "") == .orderedAscending
            case .date:
                let da = MBOXParser.parseDate(a.headers["Date"] ?? "") ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"] ?? "") ?? .distantPast
                cmp = da < db
            }
            return sortAscending ? cmp : !cmp
        }
    }

    // MARK: - Document List

    private var documentListPane: some View {
        VStack(spacing: 0) {
            bulkActionBar

            if let msg = scanResultMessage {
                HStack(spacing: 6) {
                    Image(systemName: aiSuggestions.values.contains(where: { $0 != .notPrivileged })
                          ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                        .foregroundColor(aiSuggestions.values.contains(where: { $0 != .notPrivileged }) ? .orange : .green)
                    Text(msg)
                        .font(.system(size: 10))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        withAnimation { scanResultMessage = nil }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(aiSuggestions.values.contains(where: { $0 != .notPrivileged })
                              ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            columnHeaders
            Divider()

            let sorted = filteredEmails
            List(sorted, id: \.id, selection: $selectedEmailIDs) { email in
                VStack(spacing: 0) {
                    documentRow(for: email)
                        .tag(email.id)
                    if expandedEmailID == email.id {
                        documentPreview(for: email)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 28)
            .onKeyPress(.init("1")) { assignPrivilegeAndAdvance(.attorneyClient, in: sorted); return .handled }
            .onKeyPress(.init("2")) { assignPrivilegeAndAdvance(.workProduct, in: sorted); return .handled }
            .onKeyPress(.init("3")) { assignPrivilegeAndAdvance(.jointDefense, in: sorted); return .handled }
            .onKeyPress(.init("4")) { assignPrivilegeAndAdvance(.notPrivileged, in: sorted); return .handled }
            .onKeyPress(.init("5")) { assignPrivilegeAndAdvance(.partiallyPrivileged, in: sorted); return .handled }
            .onKeyPress(.init("0")) { assignPrivilegeAndAdvance(.unreviewed, in: sorted); return .handled }
            .onKeyPress(.space) {
                if let id = selectedEmailIDs.first {
                    expandedEmailID = expandedEmailID == id ? nil : id
                }
                return .handled
            }
        }
    }

    private var bulkActionBar: some View {
        HStack(spacing: Spacing.xSmall) {
            if selectedEmailIDs.count > 1 {
                Text("\(selectedEmailIDs.count) selected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.indigo).cornerRadius(3)

                ForEach([PrivilegeDesignation.attorneyClient, .workProduct, .notPrivileged], id: \.self) { priv in
                    Button {
                        for id in selectedEmailIDs { privilegeAssignments[id] = priv }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: priv.icon).font(.system(size: 9))
                            Text(priv.rawValue).font(.system(size: 8))
                        }
                        .foregroundColor(priv.color)
                    }
                    .buttonStyle(.plain)
                }
            }

            keyboardLegend

            Spacer()

            Button {
                forensicManager.runPrivilegeScan(on: emails)
                runAISuggestions()
            } label: {
                HStack(spacing: 2) {
                    if isRunningAIScan {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 9))
                    }
                    Text("AI Privilege Scan").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.purple)
            }
            .buttonStyle(.plain)
            .disabled(isRunningAIScan)
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 3)
        .background(AppColors.backgroundSecondary.opacity(0.4))
    }

    private var keyboardLegend: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard").font(.system(size: 9)).foregroundColor(.secondary)
            Text("Quick Tag:").font(.system(size: 8)).foregroundColor(.secondary)
            legalKeyBadge("1", label: "Attorney-Client", color: .orange)
            legalKeyBadge("2", label: "Work Product", color: .blue)
            legalKeyBadge("3", label: "Joint Defense", color: .purple)
            legalKeyBadge("4", label: "Not Privileged", color: .green)
            legalKeyBadge("␣", label: "Preview", color: .blue)
        }
        .help("Select a document, then press a number key to quickly assign its privilege designation")
    }

    private func legalKeyBadge(_ key: String, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .frame(width: 12, height: 12)
                .background(color.opacity(0.15))
                .cornerRadius(2)
            Text(label).font(.system(size: 7))
        }
        .foregroundColor(color)
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            sortableHeader("PRIVILEGE", key: .privilege, width: 110)
            sortableHeader("RESPONSIVE", key: .responsive, width: 95)
            Text("ISSUES").frame(width: 80, alignment: .leading)
            Divider().frame(height: 14)
            sortableHeader("FROM", key: .from, width: 130).padding(.leading, 4)
            sortableHeader("SUBJECT", key: .subject, width: 200)
            Spacer()
            sortableHeader("DATE", key: .date, width: 80, alignment: .trailing)
            Text("BATES").frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, Spacing.xSmall).padding(.vertical, 4)
        .background(AppColors.backgroundSecondary.opacity(0.6))
    }

    private func sortableHeader(_ title: String, key: SortKey, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Button {
            if sortKey == key { sortAscending.toggle() }
            else { sortKey = key; sortAscending = true }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    private func documentRow(for email: MBOXParser.RawEmail) -> some View {
        let priv = privilegeAssignments[email.id] ?? .unreviewed
        let resp = responsivenessAssignments[email.id] ?? .unreviewed
        let issues = issueTagAssignments[email.id] ?? []
        let bates = batesManager.getBatesNumber(for: email.id)
        let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
        let subject = email.headers["Subject"] ?? "(No Subject)"

        return HStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: priv.icon).font(.system(size: 9)).foregroundColor(priv.color)
                Text(priv == .unreviewed ? "—" : priv.rawValue)
                    .font(.system(size: 9, weight: priv == .unreviewed ? .regular : .semibold))
                    .foregroundColor(priv.color)
            }
            .frame(width: 110, alignment: .leading)

            Text(resp == .unreviewed ? "—" : resp.rawValue)
                .font(.system(size: 9, weight: resp == .unreviewed ? .regular : .medium))
                .foregroundColor(resp.color)
                .frame(width: 95, alignment: .leading)

            if issues.isEmpty {
                Text("—").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.3))
                    .frame(width: 80, alignment: .leading)
            } else {
                Text("\(issues.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.indigo))
                    .frame(width: 80, alignment: .leading)
            }

            Text(from).font(.system(size: 10)).lineLimit(1).frame(width: 130, alignment: .leading).padding(.leading, 4)
            Text(subject).font(.system(size: 10)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)

            Text(ForensicReviewView.formatDate(email.headers["Date"]))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)

            if let bates {
                Text(bates).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(.purple)
                    .frame(width: 80, alignment: .trailing).lineLimit(1)
            } else {
                Text("—").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary.opacity(0.3))
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.horizontal, Spacing.xSmall).padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(rowBackground(priv: priv))
        )
        .contentShape(Rectangle())
    }

    private func rowBackground(priv: PrivilegeDesignation) -> Color {
        switch priv {
        case .attorneyClient: return Color.orange.opacity(0.04)
        case .workProduct: return Color.blue.opacity(0.04)
        case .jointDefense: return Color.purple.opacity(0.04)
        case .partiallyPrivileged: return Color.yellow.opacity(0.04)
        default: return Color.clear
        }
    }

    private func documentPreview(for email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From: \(email.headers["From"] ?? "")").font(.system(size: 10, weight: .medium))
                    Text("To: \(email.headers["To"] ?? "")").font(.system(size: 10))
                    if let cc = email.headers["Cc"], !cc.isEmpty {
                        Text("Cc: \(cc)").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button { expandedEmailID = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider()
            Text(String(email.plainBody.prefix(800)))
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(AppColors.backgroundSecondary.opacity(0.3))
        .cornerRadius(4)
    }

    // MARK: - Privilege Coding Pane

    private var privilegeCodingPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let email = selectedEmail {
                    codingHeader(email)
                    Divider()
                    privilegeSection(email)
                    if !privilegeClassifications.isEmpty { Divider(); autoPrivilegeClassificationSection(email) }
                    Divider()
                    responsivenessSection(email)
                    Divider()
                    issueTagSection(email)
                    Divider()
                    notesSection(email)
                    Divider()
                    aiSuggestionSection(email)
                    if hasV3Analysis { Divider(); piiWarningSection(email) }
                    if kgLoaded { Divider(); kgCrossReferencePanel(email) }
                    if !custodianAnalyses.isEmpty { Divider(); custodianInsightsSection(email) }
                    if hasV3Analysis { Divider(); anomalyBadgeSection(email) }
                    Divider()
                    aiPrivilegeSection(email)
                    Divider()
                    privilegeIndicators(email)
                    Divider()
                    auditTrailSection(email)
                    Divider()
                    metadataSection(email)
                } else {
                    emptyPanel
                }
            }
            .padding(12)
        }
        .background(AppColors.backgroundSecondary.opacity(0.2))
    }

    private func codingHeader(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "building.columns").foregroundColor(.indigo)
                Text("Privilege Coding").font(.system(size: 11, weight: .semibold))
                Spacer()
                if let bates = batesManager.getBatesNumber(for: email.id) {
                    Text(bates).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.purple)
                }
            }
            Text(email.headers["Subject"] ?? "(No Subject)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("From: \(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(email.headers["Date"] ?? "")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    private func privilegeSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Privilege Designation — Is this email legally protected?").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Classify whether this email is protected from disclosure. Attorney-Client = between lawyer and client. Work Product = prepared for litigation. Joint Defense = shared between allied legal teams.")
            let currentPriv = privilegeAssignments[email.id] ?? .unreviewed
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(PrivilegeDesignation.allCases) { priv in
                    Button {
                        privilegeAssignments[email.id] = priv
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: priv.icon).font(.system(size: 10))
                            Text(priv.rawValue).font(.system(size: 9, weight: currentPriv == priv ? .bold : .regular))
                        }
                        .foregroundColor(currentPriv == priv ? .white : priv.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(currentPriv == priv ? priv.color : priv.color.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if currentPriv != .unreviewed {
                Button {
                    let old = privilegeAssignments[email.id] ?? .unreviewed
                    privilegeAssignments.removeValue(forKey: email.id)
                    auditTrail.append((Date(), email.id, "Privilege", old.rawValue, "Cleared"))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle").font(.system(size: 10))
                        Text("Clear Designation").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Remove the current privilege designation and reset to Unreviewed")
            }
        }
    }

    private func responsivenessSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Responsiveness — Is this email relevant to the case?").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Mark whether this document relates to the legal matter at hand. Responsive = relevant. Not Responsive = unrelated. Partially = contains some relevant content.")
            let currentResp = responsivenessAssignments[email.id] ?? .unreviewed
            HStack(spacing: 4) {
                ForEach(ResponsivenessTag.allCases) { resp in
                    Button {
                        responsivenessAssignments[email.id] = resp
                    } label: {
                        Text(resp.rawValue)
                            .font(.system(size: 9, weight: currentResp == resp ? .bold : .regular))
                            .foregroundColor(currentResp == resp ? .white : resp.color)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(currentResp == resp ? resp.color : resp.color.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func issueTagSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Issue Tags — Categorize by topic").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Tag this email with the legal issues or topics it relates to. You can select multiple tags and create your own custom tags.")
            let current = issueTagAssignments[email.id] ?? []

            // Show assigned tags with remove buttons
            if !current.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(current.sorted(), id: \.self) { tag in
                        HStack(spacing: 2) {
                            Text(tag)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                            Button {
                                var tags = issueTagAssignments[email.id] ?? []
                                tags.remove(tag)
                                issueTagAssignments[email.id] = tags
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help("Remove \"\(tag)\" tag from this email")
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.indigo)
                        )
                    }

                    if current.count > 1 {
                        Button {
                            issueTagAssignments[email.id] = []
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "xmark.circle").font(.system(size: 9))
                                Text("Clear All").font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Remove all issue tags from this email")
                    }
                }
            }

            // Available tags to toggle
            FlowLayout(spacing: 4) {
                ForEach(definedIssueTags, id: \.self) { tag in
                    Button {
                        var tags = issueTagAssignments[email.id] ?? []
                        if tags.contains(tag) { tags.remove(tag) } else { tags.insert(tag) }
                        issueTagAssignments[email.id] = tags
                    } label: {
                        Text(tag)
                            .font(.system(size: 9, weight: current.contains(tag) ? .bold : .regular))
                            .foregroundColor(current.contains(tag) ? .white : .indigo)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(current.contains(tag) ? Color.indigo : Color.indigo.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            definedIssueTags.removeAll { $0 == tag }
                            // Also remove from all email assignments
                            for key in issueTagAssignments.keys {
                                issueTagAssignments[key]?.remove(tag)
                            }
                        } label: {
                            Label("Remove \"\(tag)\" from tag list", systemImage: "trash")
                        }
                    }
                }
            }

            HStack(spacing: 4) {
                TextField("New issue tag...", text: $newIssueTag)
                    .font(.system(size: 10))
                    .textFieldStyle(.roundedBorder)
                Button {
                    if !newIssueTag.isEmpty && !definedIssueTags.contains(newIssueTag) {
                        definedIssueTags.append(newIssueTag)
                        newIssueTag = ""
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 12)).foregroundColor(.indigo)
                }
                .buttonStyle(.plain)
                .disabled(newIssueTag.isEmpty)
            }
        }
    }

    private func notesSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reviewer Notes").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Type your observations or reasoning about this document. Notes are saved automatically.")
            TextEditor(text: Binding(
                get: { legalNotes[email.id] ?? "" },
                set: { legalNotes[email.id] = $0 }
            ))
            .font(.system(size: 10))
            .frame(minHeight: 60, maxHeight: 100)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppColors.backgroundSecondary, lineWidth: 1)
            )
        }
    }

    private func privilegeIndicators(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Auto-Detected Indicators").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("The app automatically scanned this email and found these potential privilege signals — use them as hints when deciding the designation")

            if let flags = forensicManager.privilegeFlags[email.id], !flags.isEmpty {
                ForEach(flags, id: \.self) { flag in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundColor(.orange)
                        Text(flag).font(.system(size: 9)).foregroundColor(.orange)
                    }
                }
            } else {
                Text("No privilege indicators detected")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }

            let legalTerms = detectLegalTerms(in: email)
            if !legalTerms.isEmpty {
                Divider()
                Text("Legal Terms Found").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                    .help("Legal keywords automatically detected in this email — these may indicate privilege, litigation relevance, or compliance issues")
                FlowLayout(spacing: 3) {
                    ForEach(legalTerms, id: \.self) { term in
                        Text(term)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.indigo)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.1)).cornerRadius(3)
                    }
                }
            }
        }
    }

    // MARK: - Legal Findings Banner (v4)

    private var legalFindingsBanner: some View {
        let legalFindings = backgroundManager.lastRunFindings.filter {
            $0.category == "pii" || $0.category == "legal" || $0.category == "compliance"
        }.sorted { $0.severity > $1.severity }

        return Group {
            if !legalFindings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 11)).foregroundColor(.indigo)
                    Text("\(legalFindings.count) legal/compliance findings")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.indigo)
                    Spacer()
                    Text(legalFindings.first?.title ?? "")
                        .font(.system(size: 9)).foregroundColor(.indigo.opacity(0.8)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.indigo.opacity(0.08))
            }
        }
    }

    // MARK: - AI Privilege Narrative (v4)

    private func aiPrivilegeSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundColor(.purple)
                Text("AI Privilege Analysis").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if isGeneratingPrivilege {
                    ProgressView().controlSize(.small)
                } else if aiPrivilegeNarrative.isEmpty {
                    Button("Analyze") {
                        generatePrivilegeNarrative(for: email)
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.purple)
                    .buttonStyle(.plain)
                }
            }
            if !aiPrivilegeNarrative.isEmpty {
                Text(aiPrivilegeNarrative)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(Color.purple.opacity(0.04))
        .cornerRadius(6)
    }

    private func generatePrivilegeNarrative(for email: MBOXParser.RawEmail) {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            isGeneratingPrivilege = true
            Task {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .investigation,
                    emails: [email],
                    context: "Analyze this email for attorney-client privilege, work product doctrine, or joint defense privilege. Identify legal terms, relationships, and privilege indicators."
                )
                aiPrivilegeNarrative = result ?? "AI analysis unavailable."
                isGeneratingPrivilege = false
            }
        }
        #endif
    }

    // MARK: - PDF Privilege Report (v4)

    private var pdfPrivilegeReportSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Privilege Review Report").font(.title3).fontWeight(.bold)
                Spacer()
                Button("Generate PDF") {
                    Task {
                        let privilegedEmails = emails.filter {
                            let priv = privilegeAssignments[$0.id] ?? .unreviewed
                            return priv != .unreviewed && priv != .notPrivileged
                        }
                        let target = privilegedEmails.isEmpty ? emails : privilegedEmails
                        let data = await InvestigationReportGenerator.generateReport(
                            emails: target,
                            title: "Privilege Review Report",
                            investigatorName: "Legal Reviewer"
                        )
                        #if os(macOS)
                        _ = PlatformFileSaver.saveData(data, suggestedName: "privilege_report.pdf")
                        #endif
                    }
                }
                .buttonStyle(.borderedProminent).tint(.indigo)
                Button("Done") { showPDFExport = false }
            }
            VStack(alignment: .leading, spacing: 6) {
                let reviewed = emails.filter { privilegeAssignments[$0.id] != nil && privilegeAssignments[$0.id] != .unreviewed }.count
                let privileged = emails.filter {
                    let p = privilegeAssignments[$0.id] ?? .unreviewed
                    return p == .attorneyClient || p == .workProduct || p == .jointDefense || p == .partiallyPrivileged
                }.count
                Text("Report Summary").font(.headline)
                Text("Total emails: \(emails.count)")
                Text("Reviewed: \(reviewed)")
                Text("Privileged: \(privileged)")
                Text("PII findings: \(piiFindings.count)")
                Text("Audit trail entries: \(auditTrail.count)")
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }

    // MARK: - PII Warning (v3)

    private func piiWarningSection(_ email: MBOXParser.RawEmail) -> some View {
        let emailPII = piiFindings.filter { $0.emailID == email.id }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Personal Information (PII) Detection").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Personally Identifiable Information found in this email — names, phone numbers, addresses, SSNs, etc. that may need redaction before production")
            if emailPII.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield").font(.system(size: 9)).foregroundColor(.green)
                    Text("No PII detected").font(.system(size: 9)).foregroundColor(.green)
                }
            } else {
                ForEach(emailPII) { finding in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                            .foregroundColor(finding.contextualRiskScore > 7 ? .red : .orange)
                        Text(finding.type.rawValue).font(.system(size: 9, weight: .semibold))
                            .foregroundColor(finding.contextualRiskScore > 7 ? .red : .orange)
                        Text(finding.value.prefix(20) + (finding.value.count > 20 ? "..." : ""))
                            .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                        Spacer()
                        Text("Risk: \(String(format: "%.1f", finding.contextualRiskScore))/10")
                            .font(.system(size: 8, weight: .bold)).foregroundColor(.red)
                            .help("Contextual PII risk score from 0 to 10 — higher values indicate greater exposure risk")
                    }
                    .padding(3)
                    .background(Color.red.opacity(0.04))
                    .cornerRadius(3)
                }
            }
        }
    }

    // MARK: - KG Cross-Reference (v3)

    private func kgCrossReferencePanel(_ email: MBOXParser.RawEmail) -> some View {
        let senderEmail = extractSenderEmail(from: email.headers["From"] ?? "")
        let senderNodeID = "person:\(senderEmail)"
        let neighbors = graph.neighbors(of: senderNodeID)
        let orgNeighbors = neighbors.filter { $0.type == .organization }
        let personNeighbors = neighbors.filter { $0.type == .person }

        return VStack(alignment: .leading, spacing: 4) {
            Text("Relationship Cross-Reference").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Shows this sender's connections to other people and organizations found across all emails — helps identify hidden relationships")
            if neighbors.isEmpty {
                Text("No KG data for this sender").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                if !orgNeighbors.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "building.2").font(.system(size: 8)).foregroundColor(.orange)
                        Text("Orgs:").font(.system(size: 9, weight: .medium)).foregroundColor(.orange)
                        Text(orgNeighbors.map(\.label).joined(separator: ", "))
                            .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                if !personNeighbors.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2").font(.system(size: 8)).foregroundColor(.blue)
                        Text("Connected:").font(.system(size: 9, weight: .medium)).foregroundColor(.blue)
                        Text(personNeighbors.prefix(5).map(\.label).joined(separator: ", "))
                            .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                Text("\(neighbors.count) total connections")
                    .font(.system(size: 8)).foregroundColor(.cyan)
            }
        }
        .padding(8)
        .background(Color.cyan.opacity(0.04))
        .cornerRadius(6)
    }

    private func extractSenderEmail(from raw: String) -> String {
        if let start = raw.firstIndex(of: "<"), let end = raw.firstIndex(of: ">") {
            return String(raw[raw.index(after: start)..<end]).lowercased()
        }
        return raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Anomaly Badges (v3)

    private func anomalyBadgeSection(_ email: MBOXParser.RawEmail) -> some View {
        let emailAnomalies = anomalies.filter { $0.affectedEmails.contains(email.id) }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Anomalies Detected").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Unusual patterns found in this email — unexpected sending times, format changes, or behavior that differs from the norm")
            if emailAnomalies.isEmpty {
                Text("No anomalies for this email").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(emailAnomalies) { anomaly in
                        HStack(spacing: 3) {
                            Image(systemName: anomaly.type.icon).font(.system(size: 7))
                            Text(anomaly.type.rawValue).font(.system(size: 8, weight: .medium))
                        }
                        .foregroundColor(anomaly.severity > 0.7 ? .red : anomaly.severity > 0.4 ? .orange : .yellow)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background((anomaly.severity > 0.7 ? Color.red : anomaly.severity > 0.4 ? .orange : .yellow).opacity(0.1))
                        .cornerRadius(4)
                    }
                }
            }
        }
    }

    private func metadataSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Email Headers (Metadata)").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Technical details about how the email was sent, routed, and delivered — useful for verifying authenticity")
            if let custodian = custodianManager.custodian(for: email.id) {
                HStack {
                    Text("Custodian:").font(.system(size: 10)).foregroundColor(.secondary)
                    Text(custodian).font(.system(size: 10, weight: .medium))
                }
            }
            if custodianManager.isUnderLegalHold(email.id) {
                HStack(spacing: 3) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 9)).foregroundColor(.orange)
                    Text("Under Legal Hold").font(.system(size: 10, weight: .medium)).foregroundColor(.orange)
                }
            }
            legalHoldBadge(email)
            HStack {
                Text("Attachments:").font(.system(size: 10)).foregroundColor(.secondary)
                Text("\(email.attachments.count)").font(.system(size: 10, weight: .medium))
            }
        }
    }

    // MARK: - LegalAnalysisFeatures Sections (v5)

    private func autoPrivilegeClassificationSection(_ email: MBOXParser.RawEmail) -> some View {
        let classification = privilegeClassifications.first { $0.id == email.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "brain").font(.system(size: 9)).foregroundColor(.teal)
                Text("AI Privilege Prediction").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    .help("The app's AI analyzed this email and predicts whether it's privileged — use this as a suggestion, but always verify with your own judgment")
                Spacer()
                if let cls = classification {
                    Text(cls.confidenceLevel.rawValue)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(cls.confidenceLevel == .high ? .green : cls.confidenceLevel == .medium ? .orange : .red)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background((cls.confidenceLevel == .high ? Color.green : cls.confidenceLevel == .medium ? .orange : .red).opacity(0.1))
                        .cornerRadius(3)
                        .help("ML classification confidence — High: strong privilege signals, Medium: some indicators, Low: needs manual review")
                }
            }
            if let cls = classification {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cls.classification.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(privilegeTypeColor(cls.classification))
                        Text("Privilege Score: \(String(format: "%.0f%%", cls.score * 100))")
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                            .help("ML-computed privilege likelihood — percentage confidence that this email falls under the indicated privilege category")
                    }
                    Spacer()
                    Button {
                        let mapped = mapToDesignation(cls.classification)
                        let old = privilegeAssignments[email.id] ?? .unreviewed
                        privilegeAssignments[email.id] = mapped
                        auditTrail.append((Date(), email.id, "Privilege", old.rawValue, mapped.rawValue))
                    } label: {
                        Text("Accept")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.teal))
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(privilegeTypeColor(cls.classification).opacity(0.08)))

                if !cls.reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(cls.reasons.prefix(4), id: \.self) { reason in
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.right.circle.fill").font(.system(size: 7)).foregroundColor(.teal)
                                Text(reason).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                Text("No classification available").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.teal.opacity(0.04))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func legalHoldBadge(_ email: MBOXParser.RawEmail) -> some View {
        if let hold = legalHoldDetections.first(where: { $0.id == email.id }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.lock.fill").font(.system(size: 9))
                        .foregroundColor(hold.severity > 0.85 ? .red : .orange)
                    Text(hold.holdType.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(hold.severity > 0.85 ? .red : .orange)
                    Spacer()
                    Text("Severity: \(String(format: "%.0f%%", hold.severity * 100))")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(hold.severity > 0.85 ? .red : .orange)
                        .help("Legal hold severity — higher percentages indicate stronger hold obligation signals")
                }
                Text(hold.snippet)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(6)
            .background((hold.severity > 0.85 ? Color.red : .orange).opacity(0.08))
            .cornerRadius(4)
        }
    }

    private func custodianInsightsSection(_ email: MBOXParser.RawEmail) -> some View {
        let senderAddr = extractSenderEmail(from: email.headers["From"] ?? "")
        let custodian = custodianAnalyses.first { $0.email == senderAddr }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "person.text.rectangle").font(.system(size: 9)).foregroundColor(.indigo)
                Text("Custodian Insights").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    .help("A custodian is the person responsible for these documents. This section shows their communication patterns, key contacts, and legal topics.")
            }
            if let c = custodian {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(c.name).font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text("\(c.emailCount) emails").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            Text("Privileged:").font(.system(size: 9)).foregroundColor(.secondary)
                            Text("\(c.privilegedCount)").font(.system(size: 9, weight: .bold)).foregroundColor(.orange)
                        }
                        HStack(spacing: 2) {
                            Text("Privilege Rate:").font(.system(size: 9)).foregroundColor(.secondary)
                            Text(String(format: "%.0f%%", c.privilegeRate * 100))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(c.privilegeRate > 0.5 ? .red : c.privilegeRate > 0.2 ? .orange : .green)
                                .help("Percentage of this custodian's emails that contain privilege indicators")
                        }
                    }
                    if !c.topCorrespondents.isEmpty {
                        Text("Top Correspondents").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                        FlowLayout(spacing: 3) {
                            ForEach(c.topCorrespondents.prefix(4), id: \.name) { corr in
                                Text("\(corr.name) (\(corr.count))")
                                    .font(.system(size: 8))
                                    .foregroundColor(.indigo)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(Color.indigo.opacity(0.08))
                                    .cornerRadius(3)
                            }
                        }
                    }
                    if !c.legalTopics.isEmpty {
                        Text("Legal Topics").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                        FlowLayout(spacing: 3) {
                            ForEach(c.legalTopics.prefix(6), id: \.self) { topic in
                                Text(topic)
                                    .font(.system(size: 8))
                                    .foregroundColor(.purple)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.08))
                                    .cornerRadius(3)
                            }
                        }
                    }
                }
                .padding(6)
                .background(Color.indigo.opacity(0.04))
                .cornerRadius(4)
            } else {
                Text("No custodian data for this sender").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.indigo.opacity(0.03))
        .cornerRadius(6)
    }

    private func privilegeTypeColor(_ type: LegalAnalysisFeatures.PrivilegeClassification.PrivilegeType) -> Color {
        switch type {
        case .attorneyClient: return .orange
        case .workProduct: return .blue
        case .jointDefense: return .purple
        case .commonInterest: return .cyan
        case .notPrivileged: return .green
        case .needsReview: return .yellow
        }
    }

    private func mapToDesignation(_ type: LegalAnalysisFeatures.PrivilegeClassification.PrivilegeType) -> PrivilegeDesignation {
        switch type {
        case .attorneyClient: return .attorneyClient
        case .workProduct: return .workProduct
        case .jointDefense: return .jointDefense
        case .commonInterest: return .jointDefense
        case .notPrivileged: return .notPrivileged
        case .needsReview: return .unreviewed
        }
    }

    // MARK: - AI Suggestion Section

    private func aiSuggestionSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI Suggestion").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if isRunningAIScan {
                    ProgressView().controlSize(.mini)
                }
            }

            if let suggestion = aiSuggestions[email.id] {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundColor(.purple)
                    Text("Suggested: **\(suggestion.rawValue)**")
                        .font(.system(size: 10))
                    Spacer()
                    Button {
                        let old = privilegeAssignments[email.id] ?? .unreviewed
                        privilegeAssignments[email.id] = suggestion
                        auditTrail.append((Date(), email.id, "Privilege", old.rawValue, suggestion.rawValue))
                    } label: {
                        Text("Apply")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.purple))
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(suggestion.color.opacity(0.08))
                )

                let reason = aiSuggestionReason(for: email)
                if !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                    Text("Run AI Scan to get suggestions")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func aiSuggestionReason(for email: MBOXParser.RawEmail) -> String {
        let body = email.plainBody.lowercased()
        if body.contains("attorney") || body.contains("legal advice") || body.contains("privileged") {
            return "Contains attorney-client communication markers"
        }
        if body.contains("work product") || body.contains("draft") || body.contains("litigation strategy") {
            return "Contains work product indicators"
        }
        if body.contains("joint defense") || body.contains("common interest") {
            return "Contains joint defense agreement language"
        }
        return ""
    }

    // MARK: - Audit Trail Section

    private func auditTrailSection(_ email: MBOXParser.RawEmail) -> some View {
        let emailAudit = auditTrail.filter { $0.emailID == email.id }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Audit Trail — Change History").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    .help("A log of every change made to this document's classification — who changed what and when, for legal defensibility")
                Spacer()
                if !emailAudit.isEmpty {
                    Text("\(emailAudit.count) change\(emailAudit.count == 1 ? "" : "s")")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.indigo)
                }
            }

            if emailAudit.isEmpty {
                Text("No changes recorded yet")
                    .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
            } else {
                ForEach(Array(emailAudit.suffix(5).reversed().enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 4) {
                        Image(systemName: "pencil.circle").font(.system(size: 8)).foregroundColor(.indigo)
                        Text(entry.field).font(.system(size: 9, weight: .medium))
                        Text(entry.oldValue).font(.system(size: 8)).foregroundColor(.red).strikethrough()
                        Image(systemName: "arrow.right").font(.system(size: 7)).foregroundColor(.secondary)
                        Text(entry.newValue).font(.system(size: 8, weight: .semibold)).foregroundColor(.green)
                        Spacer()
                        Text(entry.date, style: .time).font(.system(size: 7)).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var emptyPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "building.columns")
                .font(.system(size: 32))
                .foregroundColor(.indigo.opacity(0.3))

            Text("Select a document to start reviewing")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("How to review documents:").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                legalGuideRow(icon: "1.circle.fill", text: "Click any email from the document list")
                legalGuideRow(icon: "2.circle.fill", text: "Assign a privilege designation (e.g. Attorney-Client)")
                legalGuideRow(icon: "3.circle.fill", text: "Mark if it's responsive to the case")
                legalGuideRow(icon: "4.circle.fill", text: "Add issue tags and reviewer notes")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.indigo.opacity(0.05)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard shortcuts").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    legalMiniKey("1", desc: "Attorney-Client")
                    legalMiniKey("2", desc: "Work Product")
                }
                HStack(spacing: 8) {
                    legalMiniKey("3", desc: "Joint Defense")
                    legalMiniKey("4", desc: "Not Privileged")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func legalGuideRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.indigo)
            Text(text).font(.system(size: 10)).foregroundColor(.primary.opacity(0.7))
        }
    }

    private func legalMiniKey(_ key: String, desc: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 9, weight: .bold, design: .monospaced))
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
            Text(desc).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    // MARK: - Inline Email Detail (replaces list on selection)

    private func legalInlineEmailDetail(_ email: MBOXParser.RawEmail) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selectedEmailIDs.removeAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Back to List").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.indigo)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                Text(email.headers["Subject"] ?? "(No Subject)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                if let bates = batesManager.getBatesNumber(for: email.id) {
                    Text(bates).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.purple)
                }

                Text(email.headers["Date"] ?? "")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColors.backgroundSecondary.opacity(0.4))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("From:").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                            Text(email.headers["From"] ?? "").font(.system(size: 10)).lineLimit(2)
                        }
                        HStack(spacing: 4) {
                            Text("To:").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                            Text(email.headers["To"] ?? "").font(.system(size: 10)).lineLimit(2)
                        }
                        if let cc = email.headers["Cc"], !cc.isEmpty {
                            HStack(spacing: 4) {
                                Text("Cc:").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                                Text(cc).font(.system(size: 10)).lineLimit(2)
                            }
                        }
                    }

                    Divider()

                    if !email.attachments.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip").font(.system(size: 10)).foregroundColor(.secondary)
                            Text("\(email.attachments.count) attachment(s): \(email.attachments.map(\.filename).joined(separator: ", "))")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Divider()
                    }

                    Text(email.plainBody.isEmpty ? email.htmlBody : email.plainBody)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                }
                .padding(12)
            }
        }
    }

    // MARK: - Status Bar

    private var legalStatusBar: some View {
        let reviewed = privilegeAssignments.values.filter { $0 != .unreviewed }.count
        let responsive = responsivenessAssignments.values.filter { $0 == .responsive || $0 == .partiallyResponsive }.count
        let privileged = privilegeAssignments.values.filter { $0 == .attorneyClient || $0 == .workProduct || $0 == .jointDefense || $0 == .partiallyPrivileged }.count
        let progress = emails.isEmpty ? 0.0 : Double(reviewed) / Double(emails.count)
        let progressPct = Int(progress * 100)

        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.small) {
                HStack(spacing: 4) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                        .tint(progress >= 1.0 ? .green : .indigo)
                    Text("\(reviewed) of \(emails.count) reviewed (\(progressPct)%)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .help("Your review progress — assign privilege designations to documents to mark them as reviewed")

                Divider().frame(height: 12)

                HStack(spacing: 5) {
                    statusDot(.orange, count: privilegeAssignments.values.filter { $0 == .attorneyClient }.count, label: "Attorney-Client")
                    statusDot(.blue, count: privilegeAssignments.values.filter { $0 == .workProduct }.count, label: "Work Product")
                    statusDot(.purple, count: privilegeAssignments.values.filter { $0 == .jointDefense }.count, label: "Joint Defense")
                    statusDot(.green, count: privilegeAssignments.values.filter { $0 == .notPrivileged }.count, label: "Not Privileged")
                }
                .help("How your documents are distributed across privilege categories")

                Divider().frame(height: 12)

                Text("\(responsive) responsive")
                    .font(.system(size: 9)).foregroundColor(.green)
                    .help("Documents marked as responsive (relevant) to the legal matter")
                Text("\(privileged) privileged")
                    .font(.system(size: 9)).foregroundColor(.orange)
                    .help("Documents protected by legal privilege (attorney-client, work product, etc.)")

                Spacer()

                if filteredEmails.count != emails.count {
                    Text("Showing \(filteredEmails.count) of \(emails.count)")
                        .font(.system(size: 9)).foregroundColor(.indigo)
                        .help("Filters are active — not all documents are shown")
                }
            }
            .padding(.horizontal, Spacing.small).padding(.vertical, 4)
            .background(AppColors.backgroundSecondary.opacity(0.3))
        }
    }

    private func statusDot(_ color: Color, count: Int, label: String) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)").font(.system(size: 8, weight: .bold, design: .monospaced))
            Text(label).font(.system(size: 7))
        }
        .foregroundColor(count > 0 ? color : .secondary.opacity(0.5))
        .help("\(label): \(count) document\(count == 1 ? "" : "s") with this privilege designation")
    }

    // MARK: - Privilege Log Sheet

    private var privilegeLogSheet: some View {
        let logEntries = LegalAnalysisFeatures.generatePrivilegeLog(
            emails: emails,
            classifications: privilegeClassifications,
            batesPrefix: "DOC"
        )

        return VStack(spacing: 16) {
            HStack {
                Text("Privilege Log").font(.title3).fontWeight(.bold)
                Spacer()
                Text("\(logEntries.count) entries")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("Export") { exportPrivilegeLog() }
                    .buttonStyle(.borderedProminent).tint(.indigo)
                Button("Done") { showPrivilegeLog = false }
            }

            if logEntries.isEmpty {
                let manualPrivileged = emails.filter {
                    let priv = privilegeAssignments[$0.id] ?? .unreviewed
                    return priv == .attorneyClient || priv == .workProduct || priv == .jointDefense || priv == .partiallyPrivileged
                }
                if manualPrivileged.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.shield").font(.largeTitle).foregroundColor(.secondary.opacity(0.3))
                        Text("No privileged documents").foregroundColor(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(manualPrivileged, id: \.id) { email in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                let priv = privilegeAssignments[email.id] ?? .unreviewed
                                Image(systemName: priv.icon).foregroundColor(priv.color)
                                Text(priv.rawValue).font(.system(size: 11, weight: .semibold)).foregroundColor(priv.color)
                                Spacer()
                                if let bates = batesManager.getBatesNumber(for: email.id) {
                                    Text(bates).font(.system(size: 10, design: .monospaced)).foregroundColor(.purple)
                                }
                            }
                            Text(email.headers["Subject"] ?? "(No Subject)").font(.system(size: 11))
                            HStack {
                                Text("From: \(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")").font(.system(size: 10)).foregroundColor(.secondary)
                                Text(email.headers["Date"] ?? "").font(.system(size: 9)).foregroundColor(.secondary)
                            }
                            if let note = legalNotes[email.id], !note.isEmpty {
                                Text("Basis: \(note)").font(.system(size: 10)).foregroundColor(.indigo).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                List(logEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.privilegeType.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(privilegeTypeColor(entry.privilegeType))
                            Spacer()
                            Text(entry.batesBegin)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.purple)
                        }
                        Text(entry.subject).font(.system(size: 11)).lineLimit(1)
                        HStack(spacing: 8) {
                            Text("From: \(entry.from.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? entry.from)")
                                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                            Text("To: \(entry.to.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? entry.to)")
                                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                        if !entry.cc.isEmpty {
                            Text("Cc: \(entry.cc)").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Text(entry.date).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                        Text(entry.description)
                            .font(.system(size: 9))
                            .foregroundColor(.indigo)
                            .lineLimit(3)
                        if let note = legalNotes[entry.id], !note.isEmpty {
                            Text("Reviewer Note: \(note)").font(.system(size: 9)).foregroundColor(.teal).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(20)
        .frame(width: 700, height: 550)
    }

    // MARK: - Dashboard Sheet

    private var reviewDashboardSheet: some View {
        let total = emails.count
        let reviewed = privilegeAssignments.values.filter { $0 != .unreviewed }.count
        let responsive = responsivenessAssignments.values.filter { $0 == .responsive || $0 == .partiallyResponsive }.count
        let privileged = privilegeAssignments.values.filter { $0 != .unreviewed && $0 != .notPrivileged }.count
        let progress = total > 0 ? Double(reviewed) / Double(total) : 0

        return VStack(spacing: 16) {
            HStack {
                Text("Legal Review Dashboard").font(.title3).fontWeight(.bold)
                Spacer()
                Button("Done") { showDashboard = false }
            }

            HStack(spacing: 20) {
                dashStat("Total", value: "\(total)", color: .primary)
                dashStat("Reviewed", value: "\(reviewed)", color: .indigo)
                dashStat("Remaining", value: "\(total - reviewed)", color: .orange)
                dashStat("Progress", value: String(format: "%.0f%%", progress * 100), color: .green)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Privilege Distribution").font(.headline)
                ForEach(PrivilegeDesignation.allCases.filter { $0 != .unreviewed }) { priv in
                    let count = privilegeAssignments.values.filter { $0 == priv }.count
                    let pct = total > 0 ? Double(count) / Double(total) : 0
                    HStack {
                        Image(systemName: priv.icon).foregroundColor(priv.color).frame(width: 20)
                        Text(priv.rawValue).font(.system(size: 12)).frame(width: 120, alignment: .leading)
                        ProgressView(value: pct).frame(width: 120).tint(priv.color)
                        Text("\(count)").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Divider()

            HStack(spacing: 20) {
                dashStat("Responsive", value: "\(responsive)", color: .green)
                dashStat("Privileged", value: "\(privileged)", color: .orange)
                dashStat("Issues Tagged", value: "\(issueTagAssignments.values.filter { !$0.isEmpty }.count)", color: .indigo)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Review Velocity").font(.headline)
                let elapsed = max(1, Date().timeIntervalSince(reviewStartTime) / 3600)
                let velocity = Double(reviewed) / elapsed
                let eta = velocity > 0 ? Double(total - reviewed) / velocity : 0

                HStack(spacing: 20) {
                    dashStat("Per Hour", value: String(format: "%.1f", velocity), color: .teal)
                    dashStat("ETA", value: eta > 24 ? String(format: "%.0fd", eta / 24) : String(format: "%.1fh", eta), color: .orange)
                    dashStat("Session", value: String(format: "%.1fh", elapsed), color: .secondary)
                    dashStat("Audit Events", value: "\(auditTrail.count)", color: .indigo)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 500, height: 450)
    }

    private func dashStat(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private func assignPrivilegeAndAdvance(_ priv: PrivilegeDesignation, in sorted: [MBOXParser.RawEmail]) {
        if selectedEmailIDs.count > 1 {
            for id in selectedEmailIDs {
                let old = privilegeAssignments[id] ?? .unreviewed
                privilegeAssignments[id] = priv
                auditTrail.append((Date(), id, "Privilege", old.rawValue, priv.rawValue))
            }
        } else if let id = selectedEmailIDs.first {
            let old = privilegeAssignments[id] ?? .unreviewed
            privilegeAssignments[id] = priv
            auditTrail.append((Date(), id, "Privilege", old.rawValue, priv.rawValue))
            if let idx = sorted.firstIndex(where: { $0.id == id }) {
                let next = sorted[(idx + 1)...].first { (privilegeAssignments[$0.id] ?? .unreviewed) == .unreviewed }
                    ?? sorted.first { (privilegeAssignments[$0.id] ?? .unreviewed) == .unreviewed }
                if let next { selectedEmailIDs = [next.id] }
            }
        }
    }

    private func runAISuggestions() {
        isRunningAIScan = true
        var privilegeResults: [(UUID, Bool, [String], String)] = []
        for email in emails {
            let result = ForensicManager.detectPrivilege(for: email)
            privilegeResults.append((email.id, result.isLikelyPrivileged, result.indicators, email.plainBody))
        }
        Task.detached(priority: .userInitiated) {
            var suggestions: [UUID: PrivilegeDesignation] = [:]
            for (id, isLikely, indicators, plainBody) in privilegeResults {
                guard isLikely else {
                    suggestions[id] = .notPrivileged
                    continue
                }

                let indicatorText = indicators.joined(separator: " ").lowercased()
                let body = plainBody.lowercased()

                if body.contains("attorney-client") || body.contains("legal advice") ||
                   (body.contains("privileged") && body.contains("confidential")) ||
                   indicatorText.contains("legal sender") {
                    suggestions[id] = .attorneyClient
                } else if body.contains("work product") || body.contains("litigation strategy") ||
                          body.contains("draft memo") || body.contains("trial preparation") ||
                          body.contains("case analysis") || body.contains("legal memorandum") {
                    suggestions[id] = .workProduct
                } else if body.contains("joint defense") || body.contains("common interest") {
                    suggestions[id] = .jointDefense
                } else if indicatorText.contains("legal domain") || indicatorText.contains("legal subject") ||
                          indicatorText.contains("legal reference") || indicatorText.contains("confidentiality disclaimer") {
                    suggestions[id] = .partiallyPrivileged
                } else {
                    suggestions[id] = .partiallyPrivileged
                }
            }
            let finalSuggestions = suggestions
            let ac = suggestions.values.filter { $0 == .attorneyClient }.count
            let wp = suggestions.values.filter { $0 == .workProduct }.count
            let jd = suggestions.values.filter { $0 == .jointDefense }.count
            let pp = suggestions.values.filter { $0 == .partiallyPrivileged }.count
            let np = suggestions.values.filter { $0 == .notPrivileged }.count
            let privilegedTotal = ac + wp + jd + pp
            let total = suggestions.count

            var msg = "Scan complete — \(total) emails reviewed. "
            if privilegedTotal == 0 {
                msg += "No privileged communications found. All \(np) emails classified as Not Privileged."
            } else {
                var parts: [String] = []
                if ac > 0 { parts.append("\(ac) Attorney-Client") }
                if wp > 0 { parts.append("\(wp) Work Product") }
                if jd > 0 { parts.append("\(jd) Joint Defense") }
                if pp > 0 { parts.append("\(pp) Partially Privileged") }
                if np > 0 { parts.append("\(np) Not Privileged") }
                msg += "Found \(privilegedTotal) potentially privileged: \(parts.joined(separator: ", ")). Select an email to review and apply suggestions."
            }

            await MainActor.run {
                aiSuggestions = finalSuggestions
                isRunningAIScan = false
                scanResultMessage = msg
            }
        }
    }

    private func detectLegalTerms(in email: MBOXParser.RawEmail) -> [String] {
        let body = email.plainBody.lowercased()
        let terms = ["privileged", "confidential", "attorney", "counsel", "legal advice",
                     "work product", "litigation", "settlement", "deposition", "subpoena",
                     "compliance", "regulatory", "indemnif", "liability", "contract",
                     "breach", "intellectual property", "trade secret", "non-disclosure"]
        return terms.filter { body.contains($0) }
    }

    private func exportPrivilegeLog() {
        var csv = "Bates Number,From,To,Date,Subject,Privilege Designation,Basis\n"
        for email in emails {
            let priv = privilegeAssignments[email.id] ?? .unreviewed
            guard priv != .unreviewed && priv != .notPrivileged else { continue }
            let bates = batesManager.getBatesNumber(for: email.id) ?? ""
            let from = (email.headers["From"] ?? "").replacingOccurrences(of: ",", with: ";")
            let to = (email.headers["To"] ?? "").replacingOccurrences(of: ",", with: ";")
            let date = email.headers["Date"] ?? ""
            let subject = (email.headers["Subject"] ?? "").replacingOccurrences(of: ",", with: ";")
            let basis = (legalNotes[email.id] ?? "").replacingOccurrences(of: ",", with: ";")
            csv += "\(bates),\(from),\(to),\(date),\(subject),\(priv.rawValue),\(basis)\n"
        }
        #if os(macOS)
        _ = PlatformFileSaver.saveText(csv, suggestedName: "privilege_log.csv")
        #endif
    }
}

// MARK: - Flow Layout Helper

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
