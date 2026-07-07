import SwiftUI

struct ForensicReviewView: View {
    let emails: [MBOXParser.RawEmail]
    @Binding var selectedEmailIDs: Set<UUID>

    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var reviewManager = ForensicReviewManager.shared
    @ObservedObject private var batesManager = BatesNumberingManager.shared
    @ObservedObject private var custodianManager = CustodianManager.shared
    @ObservedObject private var reviewBatchManager = ReviewBatchManager.shared

    // MARK: - Sort State
    enum SortKey: String, CaseIterable {
        case tag, bates, risk, from, to, subject, date, attachments
    }
    @State private var sortKey: SortKey = .date
    @State private var sortAscending = false

    // MARK: - Faceted Filter State
    @State private var filterTags: Set<ForensicManager.EvidenceTag> = []
    @State private var filterRisk: FilterRisk = .all
    @State private var filterAttachments: FilterToggle = .all
    @State private var filterPrivilege: FilterToggle = .all
    @State private var filterReviewed: FilterToggle = .all
    @State private var filterSearchText = ""

    enum FilterRisk: String, CaseIterable {
        case all = "All"
        case critical = "Critical"
        case high = "High"
        case medium = "Medium"
        case low = "Low"
        case safe = "Safe"
    }

    enum FilterToggle: String, CaseIterable {
        case all = "All"
        case yes = "Yes"
        case no = "No"
    }

    // MARK: - UI State
    @State private var showCodingPanel = true
    @State private var showHotFolders = false
    @State private var showProductionSets = false
    @State private var showDashboard = false
    @State private var showNewHotFolder = false
    @State private var showNewProductionSet = false
    @State private var newFolderName = ""
    @State private var newProdName = ""
    @State private var newProdPrefix = "PROD"
    @State private var noteText = ""
    @State private var noteCategory: ForensicReviewManager.ReviewerNote.NoteCategory = .general
    @State private var qcSampleIDs: Set<UUID> = []
    @State private var showCrossPartyFilter = false
    @State private var crossPartyFrom = ""
    @State private var crossPartyTo = ""
    @State private var expandedEmailID: UUID? = nil
    @State private var hoveringEmailID: UUID? = nil

    // MARK: - Forensic Analysis Features State
    @State private var evidenceScores: [UUID: ForensicAnalysisFeatures.EvidenceRelevanceScore] = [:]
    @State private var forensicTimeline: [ForensicAnalysisFeatures.ForensicTimelineEvent] = []
    @State private var suspiciousPatterns: [ForensicAnalysisFeatures.SuspiciousPattern] = []
    @State private var evidenceClusters: [ForensicAnalysisFeatures.EvidenceCluster] = []
    @State private var metadataAnomalies: [ForensicAnalysisFeatures.MetadataAnomaly] = []
    @State private var hasForensicAnalysis = false
    @StateObject private var coordinator = AnalysisCoordinator()
    @State private var showTutorial = false

    private var selectedEmail: MBOXParser.RawEmail? {
        guard let id = selectedEmailIDs.first else { return nil }
        return emails.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            facetedFilterBar

            if filteredEmails.count != emails.count {
                Label {
                    Text("Showing \(filteredEmails.count) of \(emails.count) emails matching current filters. Use tags, risk scores, and hot folders to narrow your forensic review scope.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(AppColors.primary)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.primary.opacity(0.1))
                .cornerRadius(CornerRadius.small)
                .padding(.horizontal, Spacing.xSmall)
                .padding(.vertical, Spacing.xxSmall)
            }

            Divider()

            #if os(macOS)
            HSplitView {
                if let email = selectedEmail {
                    inlineEmailDetail(email)
                        .frame(minWidth: 400)
                } else {
                    tablePane
                        .frame(minWidth: 500)
                }
                if showCodingPanel, selectedEmail != nil {
                    codingPane
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 500)
                }
            }
            #else
            if selectedEmail != nil {
                inlineEmailDetail(selectedEmail!)
                    .overlay(alignment: .topLeading) {
                        Button { selectedEmailIDs.removeAll() } label: {
                            Label("Back to List", systemImage: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
            } else {
                tablePane
            }
            #endif

            forensicStatusBar
        }
        .overlay { if AnalysisCoordinator.isEnabled { AnalysisProgressOverlay(coordinator: coordinator) } }
        .featureTutorial(.forensicReview, key: "forensic_review_tutorial_seen", isPresented: $showTutorial)
        .sheet(isPresented: $showDashboard) { dashboardSheet }
        .sheet(isPresented: $showProductionSets) { productionSetsSheet }
        .task { await loadForensicFeatures() }
    }

    // MARK: - Faceted Filter Bar

    private var facetedFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterLabel("Filters", icon: "line.3.horizontal.decrease.circle")

                tagFilterMenu
                riskFilterMenu
                toggleFilter("Attach", icon: "paperclip", value: $filterAttachments)
                toggleFilter("Privilege", icon: "lock.shield", value: $filterPrivilege)
                toggleFilter("Reviewed", icon: "checkmark.circle", value: $filterReviewed)

                Divider().frame(height: 14)

                TextField("Search...", text: $filterSearchText)
                    .font(.system(size: 10))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                if hasActiveFilters {
                    Button("Clear All") {
                        clearFilters()
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("\(filteredEmails.count)/\(emails.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)

                Divider().frame(height: 14)

                Button { showHotFolders.toggle() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "flame").font(.system(size: 9))
                        Text("Hot Docs").font(.system(size: 9, weight: .medium))
                        if !reviewManager.hotFolders.isEmpty {
                            Text("\(reviewManager.hotFolders.count)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(.red))
                        }
                    }
                    .foregroundColor(showHotFolders ? .red : .secondary)
                }
                .buttonStyle(.plain)

                Button { showProductionSets = true } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "shippingbox").font(.system(size: 9))
                        Text("Productions").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.secondary)
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
                .help(showCodingPanel ? "Hide coding panel" : "Show coding panel")

                TutorialHelpButton(showTutorial: $showTutorial)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(AppColors.backgroundSecondary.opacity(0.5))
    }

    private var tagFilterMenu: some View {
        Menu {
            ForEach(ForensicManager.EvidenceTag.allCases, id: \.self) { tag in
                Button {
                    if filterTags.contains(tag) { filterTags.remove(tag) }
                    else { filterTags.insert(tag) }
                } label: {
                    HStack {
                        Label(tag.rawValue, systemImage: tag.icon)
                        if filterTags.contains(tag) { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            filterChip("Tag", active: !filterTags.isEmpty,
                       detail: filterTags.isEmpty ? nil : "\(filterTags.count)")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 70)
    }

    private var riskFilterMenu: some View {
        Menu {
            ForEach(FilterRisk.allCases, id: \.self) { level in
                Button {
                    filterRisk = level
                } label: {
                    HStack {
                        Text(level.rawValue)
                        if filterRisk == level { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            filterChip("Risk", active: filterRisk != .all,
                       detail: filterRisk == .all ? nil : filterRisk.rawValue)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 70)
    }

    private func toggleFilter(_ title: String, icon: String, value: Binding<FilterToggle>) -> some View {
        Menu {
            ForEach(FilterToggle.allCases, id: \.self) { opt in
                Button {
                    value.wrappedValue = opt
                } label: {
                    HStack {
                        Text(opt.rawValue)
                        if value.wrappedValue == opt { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            filterChip(title, active: value.wrappedValue != .all,
                       detail: value.wrappedValue == .all ? nil : value.wrappedValue.rawValue)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 80)
    }

    private func filterLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(.secondary)
    }

    private func filterChip(_ title: String, active: Bool, detail: String?) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 9, weight: active ? .semibold : .regular))
            if let d = detail {
                Text(d)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(.blue))
            }
        }
        .foregroundColor(active ? .blue : .secondary)
    }

    private var hasActiveFilters: Bool {
        !filterTags.isEmpty || filterRisk != .all || filterAttachments != .all ||
        filterPrivilege != .all || filterReviewed != .all || !filterSearchText.isEmpty
    }

    private func clearFilters() {
        filterTags = []
        filterRisk = .all
        filterAttachments = .all
        filterPrivilege = .all
        filterReviewed = .all
        filterSearchText = ""
    }

    // MARK: - Filtered & Sorted Emails

    private var filteredEmails: [MBOXParser.RawEmail] {
        var result = emails

        if !filterTags.isEmpty {
            result = result.filter { filterTags.contains(forensicManager.tagForEmail($0.id)) }
        }

        switch filterRisk {
        case .all: break
        case .critical: result = result.filter { ForensicManager.assessRisk(for: $0).score >= 80 }
        case .high: result = result.filter { r in let s = ForensicManager.assessRisk(for: r).score; return s >= 55 && s < 80 }
        case .medium: result = result.filter { r in let s = ForensicManager.assessRisk(for: r).score; return s >= 30 && s < 55 }
        case .low: result = result.filter { r in let s = ForensicManager.assessRisk(for: r).score; return s >= 10 && s < 30 }
        case .safe: result = result.filter { ForensicManager.assessRisk(for: $0).score < 10 }
        }

        switch filterAttachments {
        case .all: break
        case .yes: result = result.filter { !$0.attachments.isEmpty }
        case .no: result = result.filter { $0.attachments.isEmpty }
        }

        switch filterPrivilege {
        case .all: break
        case .yes: result = result.filter { forensicManager.privilegeFlags[$0.id] != nil || forensicManager.tagForEmail($0.id) == .privileged }
        case .no: result = result.filter { forensicManager.privilegeFlags[$0.id] == nil && forensicManager.tagForEmail($0.id) != .privileged }
        }

        switch filterReviewed {
        case .all: break
        case .yes: result = result.filter { forensicManager.tagForEmail($0.id) != .none }
        case .no: result = result.filter { forensicManager.tagForEmail($0.id) == .none }
        }

        if !filterSearchText.isEmpty {
            let q = filterSearchText.lowercased()
            result = result.filter { email in
                (email.headers["Subject"] ?? "").lowercased().contains(q) ||
                (email.headers["From"] ?? "").lowercased().contains(q) ||
                (email.headers["To"] ?? "").lowercased().contains(q) ||
                email.rawSource.lowercased().contains(q)
            }
        }

        if showCrossPartyFilter && (!crossPartyFrom.isEmpty || !crossPartyTo.isEmpty) {
            result = result.filter { email in
                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                let matchFrom = crossPartyFrom.isEmpty || from.contains(crossPartyFrom.lowercased())
                let matchTo = crossPartyTo.isEmpty || to.contains(crossPartyTo.lowercased())
                return matchFrom && matchTo
            }
        }

        return sortEmails(result)
    }

    private func sortEmails(_ emails: [MBOXParser.RawEmail]) -> [MBOXParser.RawEmail] {
        emails.sorted { a, b in
            let result: Bool
            switch sortKey {
            case .tag:
                result = forensicManager.tagForEmail(a.id).rawValue < forensicManager.tagForEmail(b.id).rawValue
            case .bates:
                result = (batesManager.getBatesNumber(for: a.id) ?? "") < (batesManager.getBatesNumber(for: b.id) ?? "")
            case .risk:
                result = ForensicManager.assessRisk(for: a).score < ForensicManager.assessRisk(for: b).score
            case .from:
                result = (a.headers["From"] ?? "").localizedCaseInsensitiveCompare(b.headers["From"] ?? "") == .orderedAscending
            case .to:
                result = (a.headers["To"] ?? "").localizedCaseInsensitiveCompare(b.headers["To"] ?? "") == .orderedAscending
            case .subject:
                result = (a.headers["Subject"] ?? "").localizedCaseInsensitiveCompare(b.headers["Subject"] ?? "") == .orderedAscending
            case .date:
                let da = MBOXParser.parseDate(a.headers["Date"] ?? "") ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"] ?? "") ?? .distantPast
                result = da < db
            case .attachments:
                result = a.attachments.count < b.attachments.count
            }
            return sortAscending ? result : !result
        }
    }

    // MARK: - Table Pane (Left)

    private var tablePane: some View {
        VStack(spacing: 0) {
            actionBar
            if showCrossPartyFilter { crossPartyFilterBar }
            if showHotFolders { hotFolderBar }
            columnHeaders
            Divider()

            let sorted = filteredEmails
            List(sorted, id: \.id, selection: $selectedEmailIDs) { email in
                VStack(spacing: 0) {
                    tableRow(for: email)
                        .tag(email.id)
                    if expandedEmailID == email.id {
                        inlinePreview(for: email)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 28)
            .onKeyPress(.init("1")) { tagAndAdvance(.relevant, in: sorted); return .handled }
            .onKeyPress(.init("2")) { tagAndAdvance(.privileged, in: sorted); return .handled }
            .onKeyPress(.init("3")) { tagAndAdvance(.irrelevant, in: sorted); return .handled }
            .onKeyPress(.init("4")) { tagAndAdvance(.flagged, in: sorted); return .handled }
            .onKeyPress(.init("5")) { tagAndAdvance(.suspicious, in: sorted); return .handled }
            .onKeyPress(.init("0")) { tagAndAdvance(.none, in: sorted); return .handled }
            .onKeyPress(.space) {
                if let id = selectedEmailIDs.first {
                    expandedEmailID = expandedEmailID == id ? nil : id
                }
                return .handled
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: Spacing.xSmall) {
            if selectedEmailIDs.count > 1 {
                Text("\(selectedEmailIDs.count) selected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.blue).cornerRadius(3)

                ForEach(ForensicManager.EvidenceTag.allCases.filter { $0 != .none }, id: \.self) { tag in
                    Button {
                        for id in selectedEmailIDs { forensicManager.tag(id, as: tag) }
                    } label: {
                        Image(systemName: tag.icon).font(.system(size: 10)).foregroundColor(tag.color)
                    }
                    .buttonStyle(.plain).help("Tag all as \(tag.rawValue)")
                }

                Button {
                    for id in selectedEmailIDs { forensicManager.tag(id, as: .none) }
                } label: {
                    Image(systemName: "tag.slash").font(.system(size: 10)).foregroundColor(.red)
                }
                .buttonStyle(.plain).help("Remove tags from all selected")

                Divider().frame(height: 14)

                hotFolderAddMenu
            }

            keyboardLegend

            Spacer()

            Button { showCrossPartyFilter.toggle() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "person.2").font(.system(size: 9))
                    Text("Party").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(showCrossPartyFilter ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                let ids = forensicManager.qcSample(from: emails, percentage: 0.1)
                qcSampleIDs = Set(ids)
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "dice").font(.system(size: 9))
                    Text("QC 10%").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button { forensicManager.runPrivilegeScan(on: emails) } label: {
                HStack(spacing: 2) {
                    Image(systemName: "lock.shield").font(.system(size: 9))
                    Text("Privilege Scan").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(forensicManager.privilegeFlags.isEmpty ? .secondary : .orange)
            }
            .buttonStyle(.plain)

            if reviewManager.reviewQueueMode {
                Button {
                    reviewManager.stopReviewQueue()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 9))
                        Text("Stop Queue").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    startQueueReview()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "play.circle").font(.system(size: 9))
                        Text("Queue Review").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("Start linear review queue through unreviewed emails")
            }
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 3)
        .background(AppColors.backgroundSecondary.opacity(0.4))
    }

    private var keyboardLegend: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard").font(.system(size: 9)).foregroundColor(.secondary)
            Text("Quick Tag:").font(.system(size: 8)).foregroundColor(.secondary)
            keyBadge("1", label: "Relevant", color: .green)
            keyBadge("2", label: "Privileged", color: .orange)
            keyBadge("3", label: "Irrelevant", color: .gray)
            keyBadge("4", label: "Flagged", color: .red)
            keyBadge("5", label: "Suspicious", color: .purple)
            keyBadge("0", label: "Clear", color: .secondary)
            keyBadge("␣", label: "Preview", color: .blue)
        }
        .help("Select an email, then press a number key to quickly tag it. Use Space to preview the full email.")
    }

    private func keyBadge(_ key: String, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .frame(width: 12, height: 12)
                .background(color.opacity(0.15))
                .cornerRadius(2)
            Text(label)
                .font(.system(size: 8))
        }
        .foregroundColor(color)
    }

    private var hotFolderAddMenu: some View {
        Menu {
            if reviewManager.hotFolders.isEmpty {
                Button("Create Hot Folder...") { showNewHotFolder = true }
            } else {
                ForEach(reviewManager.hotFolders) { folder in
                    Button {
                        reviewManager.addToHotFolder(folder.id, emailIDs: Array(selectedEmailIDs))
                    } label: {
                        Label("Add to \(folder.name)", systemImage: "flame")
                    }
                }
                Divider()
                Button("New Folder...") { showNewHotFolder = true }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "flame").font(.system(size: 9))
                Text("Hot").font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(.red)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 50)
        .popover(isPresented: $showNewHotFolder) {
            VStack(spacing: 8) {
                Text("New Hot Folder").font(.headline)
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showNewHotFolder = false; newFolderName = "" }
                    Spacer()
                    Button("Create") {
                        if !newFolderName.isEmpty {
                            reviewManager.createHotFolder(name: newFolderName)
                            if !selectedEmailIDs.isEmpty {
                                reviewManager.addToHotFolder(reviewManager.hotFolders.last!.id, emailIDs: Array(selectedEmailIDs))
                            }
                            newFolderName = ""
                            showNewHotFolder = false
                        }
                    }
                    .disabled(newFolderName.isEmpty)
                }
            }
            .padding()
            .frame(width: 250)
        }
    }

    // MARK: - Cross-Party Filter

    private var crossPartyFilterBar: some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: "person.2").font(.system(size: 10)).foregroundColor(.blue)
            TextField("From contains...", text: $crossPartyFrom)
                .font(.system(size: 10)).textFieldStyle(.roundedBorder).frame(width: 140)
            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundColor(.secondary)
            TextField("To contains...", text: $crossPartyTo)
                .font(.system(size: 10)).textFieldStyle(.roundedBorder).frame(width: 140)
            if !crossPartyFrom.isEmpty || !crossPartyTo.isEmpty {
                Button("Clear") { crossPartyFrom = ""; crossPartyTo = "" }
                    .font(.system(size: 9)).buttonStyle(.plain).foregroundColor(.red)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xSmall).padding(.vertical, 3)
        .background(Color.blue.opacity(0.05))
    }

    // MARK: - Hot Folder Bar

    private var hotFolderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.system(size: 10)).foregroundColor(.red)

                ForEach(reviewManager.hotFolders) { folder in
                    Button {
                        let ids = Set(folder.emailIDs)
                        filterTags = []
                        filterSearchText = ""
                        selectedEmailIDs = ids.isEmpty ? [] : Set([folder.emailIDs.first!])
                    } label: {
                        HStack(spacing: 3) {
                            Text(folder.name).font(.system(size: 9, weight: .medium))
                            Text("\(folder.emailIDs.count)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 3)
                                .background(Capsule().fill(.red.opacity(0.7)))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.red.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            reviewManager.deleteHotFolder(folder.id)
                        } label: {
                            Label("Delete Folder", systemImage: "trash")
                        }
                    }
                }

                Button { showNewHotFolder = true } label: {
                    Image(systemName: "plus.circle").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .background(Color.red.opacity(0.03))
    }

    // MARK: - Column Headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            sortableHeader("TAG", key: .tag, width: 68)
            sortableHeader("BATES #", key: .bates, width: 90)
            sortableHeader("RISK", key: .risk, width: 42, alignment: .center)
            Divider().frame(height: 14)
            sortableHeader("FROM", key: .from, width: 130).padding(.leading, 4)
            sortableHeader("TO", key: .to, width: 110)
            sortableHeader("SUBJECT", key: .subject, width: 200)
            Spacer()
            sortableHeader("DATE", key: .date, width: 80, alignment: .trailing)
            sortableHeader("ATT", key: .attachments, width: 24, alignment: .center)
                .help("Attachment count")
            Text("NOTES").frame(width: 36, alignment: .center)
            Text("STATUS").frame(width: 60, alignment: .center)
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

    // MARK: - Table Row

    private func tableRow(for email: MBOXParser.RawEmail) -> some View {
        let tag = forensicManager.tagForEmail(email.id)
        let risk = ForensicManager.assessRisk(for: email)
        let bates = batesManager.getBatesNumber(for: email.id)
        let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
        let to = email.headers["To"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let subject = email.headers["Subject"] ?? "(No Subject)"
        let isReviewed = forensicManager.tagForEmail(email.id) != .none
        let isHeld = custodianManager.isUnderLegalHold(email.id)
        let isPrivFlagged = forensicManager.privilegeFlags[email.id] != nil
        let isQC = qcSampleIDs.contains(email.id)
        let noteCount = reviewManager.notesCount(for: email.id)

        return HStack(spacing: 0) {
            // Evidence relevance badge
            evidenceRelevanceBadge(for: email.id)
                .padding(.trailing, 4)

            // Tag
            if tag != .none {
                Text(tag.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(tag.color)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(tag.color.opacity(0.12)).cornerRadius(2)
                    .frame(width: 68, alignment: .leading)
                    .contextMenu {
                        Button(role: .destructive) {
                            forensicManager.tag(email.id, as: .none)
                        } label: {
                            Label("Remove Tag", systemImage: "tag.slash")
                        }
                        Divider()
                        ForEach(ForensicManager.EvidenceTag.allCases.filter { $0 != .none && $0 != tag }, id: \.self) { otherTag in
                            Button {
                                forensicManager.tag(email.id, as: otherTag)
                            } label: {
                                Label("Change to \(otherTag.rawValue)", systemImage: otherTag.icon)
                            }
                        }
                    }
            } else if isPrivFlagged {
                HStack(spacing: 1) {
                    Image(systemName: "lock.shield").font(.system(size: 7))
                    Text("Priv?").font(.system(size: 8, weight: .medium)).help("Possible privilege flags detected — review required")
                }
                .foregroundColor(.orange).frame(width: 68, alignment: .leading)
            } else {
                Text("—").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.3))
                    .frame(width: 68, alignment: .leading)
            }

            // Bates
            if let bates {
                Text(bates).font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.purple).frame(width: 90, alignment: .leading).lineLimit(1)
            } else {
                Text("—").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary.opacity(0.3))
                    .frame(width: 90, alignment: .leading)
            }

            // Risk
            Text("\(risk.score)")
                .font(.system(size: 9, weight: risk.score > 0 ? .bold : .regular, design: .monospaced))
                .foregroundColor(riskColor(risk.score))
                .frame(width: 42, alignment: .center)
                .help("Risk score 0-100. Safe: 0-20, Low: 21-40, Medium: 41-60, High: 61-80, Critical: 81-100")

            // From / To / Subject
            Text(from).font(.system(size: 10)).lineLimit(1).frame(width: 130, alignment: .leading).padding(.leading, 4)
            Text(to).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
            Text(subject).font(.system(size: 10)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)

            // Date
            Text(Self.formatDate(email.headers["Date"]))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)

            // Attachments
            if !email.attachments.isEmpty {
                Text("\(email.attachments.count)").font(.system(size: 9, weight: .medium)).foregroundColor(.blue)
                    .frame(width: 24, alignment: .center)
            } else {
                Text("").frame(width: 24)
            }

            // Notes indicator
            if noteCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "note.text").font(.system(size: 7))
                    Text("\(noteCount)").font(.system(size: 8, weight: .medium))
                }
                .foregroundColor(.blue).frame(width: 36, alignment: .center)
            } else {
                Text("").frame(width: 36)
            }

            // Status icons
            HStack(spacing: 2) {
                if isHeld { Image(systemName: "lock.shield.fill").font(.system(size: 8)).foregroundColor(.orange) }
                if isQC { Image(systemName: "dice.fill").font(.system(size: 8)).foregroundColor(.blue) }
                if isReviewed {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 8)).foregroundColor(.green)
                } else {
                    Image(systemName: "circle").font(.system(size: 8)).foregroundColor(.secondary.opacity(0.3))
                }
            }
            .frame(width: 60, alignment: .center)
        }
        .padding(.horizontal, Spacing.xSmall).padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(rowBackground(email: email, isQC: isQC))
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(AnimationTiming.fast) { hoveringEmailID = h ? email.id : nil } }
    }

    private func rowBackground(email: MBOXParser.RawEmail, isQC: Bool) -> Color {
        if isQC { return Color.blue.opacity(0.04) }
        if hoveringEmailID == email.id { return AppColors.primary.opacity(0.06) }
        let tag = forensicManager.tagForEmail(email.id)
        if tag == .privileged { return Color.orange.opacity(0.03) }
        if tag == .suspicious { return Color.purple.opacity(0.03) }
        if tag == .flagged { return Color.red.opacity(0.03) }
        return Color.clear
    }

    // MARK: - Inline Preview (Space Key)

    private func inlinePreview(for email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From: \(email.headers["From"] ?? "")").font(.system(size: 10, weight: .medium))
                    Text("To: \(email.headers["To"] ?? "")").font(.system(size: 10))
                    if let cc = email.headers["Cc"], !cc.isEmpty {
                        Text("Cc: \(cc)").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Text("Date: \(email.headers["Date"] ?? "")").font(.system(size: 10)).foregroundColor(.secondary)
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

    // MARK: - Coding Pane (Right Panel)

    private var codingPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let email = selectedEmail {
                    codingPaneHeader(email)
                    Divider()
                    documentPreview(email)
                    Divider()
                    evidenceTagSection(email)
                    Divider()
                    notesSection(email)
                    Divider()
                    metadataSection(email)
                    if hasForensicAnalysis {
                        Divider()
                        metadataAnomalySection(email: email)
                        Divider()
                        suspiciousPatternsSection
                    }
                    Divider()
                    hotFolderSection(email)
                    productionSection(email)
                } else {
                    emptyCodePanel
                }
            }
            .padding(12)
        }
        .background(AppColors.backgroundSecondary.opacity(0.2))
    }

    private func codingPaneHeader(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass").foregroundColor(.blue)
                Text("Coding Panel").font(.system(size: 11, weight: .semibold))
                    .help("Review and classify the selected email here — read the preview, assign a tag, and add notes")
                Spacer()
                if let bates = batesManager.getBatesNumber(for: email.id) {
                    Text(bates).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.purple)
                        .help("Bates number — a unique tracking ID assigned to this document for legal reference")
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

    private func documentPreview(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Document Preview").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    .help("A quick look at the email content — read this to decide how to tag the email")
                Spacer()
            }
            Text(String(email.plainBody.prefix(1200)))
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.85))
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidenceTagSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Evidence Tag — Click to classify this email").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .help("Classify this email by clicking a tag below. Relevant = important evidence. Privileged = legally protected. Flagged = needs attention. Suspicious = potentially tampered.")
            HStack(spacing: 4) {
                ForEach(ForensicManager.EvidenceTag.allCases, id: \.self) { tagOpt in
                    Button {
                        forensicManager.tag(email.id, as: tagOpt)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tagOpt.icon)
                                .font(.system(size: 12))
                                .foregroundColor(tagOpt.color)
                            Text(tagOpt.rawValue)
                                .font(.system(size: 8))
                                .foregroundColor(forensicManager.tagForEmail(email.id) == tagOpt ? tagOpt.color : .secondary)
                        }
                        .frame(width: 50, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(forensicManager.tagForEmail(email.id) == tagOpt ? tagOpt.color.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(forensicManager.tagForEmail(email.id) == tagOpt ? tagOpt.color : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if forensicManager.tagForEmail(email.id) != .none {
                Button(role: .destructive) {
                    forensicManager.tag(email.id, as: .none)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.slash").font(.system(size: 9))
                        Text("Remove Tag").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            if let flags = forensicManager.privilegeFlags[email.id], !flags.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 9)).foregroundColor(.orange)
                    Text("Privilege indicators: \(flags.joined(separator: ", "))")
                        .font(.system(size: 9)).foregroundColor(.orange)
                }
            }
        }
    }

    private func notesSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("\(reviewManager.emailNotes[email.id]?.count ?? 0)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.blue)
            }

            if let notes = reviewManager.emailNotes[email.id], !notes.isEmpty {
                ForEach(notes) { note in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: note.category.icon)
                            .font(.system(size: 9))
                            .foregroundColor(note.category.color)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(note.text).font(.system(size: 10))
                            HStack {
                                Text(note.author).font(.system(size: 8)).foregroundColor(.secondary)
                                Text(note.timestamp, style: .relative).font(.system(size: 8)).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            reviewManager.deleteNote(note.id, from: email.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(AppColors.backgroundSecondary.opacity(0.5)))
                }
            }

            HStack(spacing: 4) {
                Menu {
                    ForEach(ForensicReviewManager.ReviewerNote.NoteCategory.allCases, id: \.self) { cat in
                        Button {
                            noteCategory = cat
                        } label: {
                            Label(cat.rawValue, systemImage: cat.icon)
                        }
                    }
                } label: {
                    Image(systemName: noteCategory.icon)
                        .font(.system(size: 10))
                        .foregroundColor(noteCategory.color)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)

                TextField("Add note...", text: $noteText)
                    .font(.system(size: 10))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !noteText.isEmpty {
                            reviewManager.addNote(to: email.id, text: noteText, category: noteCategory)
                            noteText = ""
                        }
                    }

                Button {
                    if !noteText.isEmpty {
                        reviewManager.addNote(to: email.id, text: noteText, category: noteCategory)
                        noteText = ""
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 12)).foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .disabled(noteText.isEmpty)
            }
        }
    }

    private func metadataSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Metadata").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)

            let risk = ForensicManager.assessRisk(for: email)
            HStack {
                Text("Risk Score:").font(.system(size: 10)).foregroundColor(.secondary)
                Text("\(risk.score)/100").font(.system(size: 10, weight: .bold)).foregroundColor(riskColor(risk.score))
                    .help("Risk score 0-100. Safe: 0-20, Low: 21-40, Medium: 41-60, High: 61-80, Critical: 81-100")
                Text(risk.level.rawValue).font(.system(size: 9)).foregroundColor(.secondary)
            }

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

            HStack {
                Text("Attachments:").font(.system(size: 10)).foregroundColor(.secondary)
                Text("\(email.attachments.count)").font(.system(size: 10, weight: .medium))
            }

            if let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"] {
                Text("Message-ID: \(msgID)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func hotFolderSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hot Folders").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            let memberOf = reviewManager.hotFolders.filter { $0.emailIDs.contains(email.id) }
            if memberOf.isEmpty {
                Text("Not in any hot folder").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                ForEach(memberOf) { folder in
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill").font(.system(size: 8)).foregroundColor(.red)
                        Text(folder.name).font(.system(size: 10))
                        Spacer()
                        Button {
                            reviewManager.removeFromHotFolder(folder.id, emailIDs: [email.id])
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 9)).foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !reviewManager.hotFolders.isEmpty {
                Menu("Add to folder...") {
                    ForEach(reviewManager.hotFolders) { folder in
                        Button(folder.name) {
                            reviewManager.addToHotFolder(folder.id, emailIDs: [email.id])
                        }
                    }
                }
                .font(.system(size: 9))
            }
        }
    }

    private func productionSection(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Production Sets").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            let memberOf = reviewManager.productionSets.filter { $0.emailIDs.contains(email.id) }
            if memberOf.isEmpty {
                Text("Not in any production").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                ForEach(memberOf) { prod in
                    HStack(spacing: 4) {
                        Image(systemName: prod.status.icon).font(.system(size: 8)).foregroundColor(prod.status.color)
                        Text(prod.name).font(.system(size: 10))
                        Text(prod.status.rawValue).font(.system(size: 8)).foregroundColor(prod.status.color)
                        Spacer()
                        Button(role: .destructive) {
                            reviewManager.removeFromProductionSet(prod.id, emailIDs: [email.id])
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from \(prod.name)")
                    }
                }
            }

            if !reviewManager.productionSets.isEmpty {
                HStack(spacing: 8) {
                    Menu("Add to production...") {
                        ForEach(reviewManager.productionSets) { prod in
                            Button(prod.name) {
                                reviewManager.addToProductionSet(prod.id, emailIDs: [email.id])
                            }
                        }
                    }
                    .font(.system(size: 9))

                    if !memberOf.isEmpty {
                        Menu("Remove from production...") {
                            ForEach(memberOf) { prod in
                                Button(prod.name, role: .destructive) {
                                    reviewManager.removeFromProductionSet(prod.id, emailIDs: [email.id])
                                }
                            }
                        }
                        .font(.system(size: 9))
                    }
                }
            }
        }
    }

    private var emptyCodePanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(.blue.opacity(0.3))

            Text("Select an email to start reviewing")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("How to review emails:").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                guideRow(icon: "1.circle.fill", color: .blue, text: "Click any email from the list on the left")
                guideRow(icon: "2.circle.fill", color: .blue, text: "Read the preview and check its metadata here")
                guideRow(icon: "3.circle.fill", color: .blue, text: "Tag it as Relevant, Privileged, Flagged, etc.")
                guideRow(icon: "4.circle.fill", color: .blue, text: "Add notes to record your observations")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.05)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard shortcuts").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    miniKey("1", desc: "Relevant")
                    miniKey("2", desc: "Privileged")
                    miniKey("3", desc: "Irrelevant")
                }
                HStack(spacing: 8) {
                    miniKey("4", desc: "Flagged")
                    miniKey("5", desc: "Suspicious")
                    miniKey("0", desc: "Clear tag")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func guideRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
            Text(text).font(.system(size: 10)).foregroundColor(.primary.opacity(0.7))
        }
    }

    private func miniKey(_ key: String, desc: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 9, weight: .bold, design: .monospaced))
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
            Text(desc).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    // MARK: - Inline Email Detail (replaces list on selection)

    private func inlineEmailDetail(_ email: MBOXParser.RawEmail) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selectedEmailIDs.removeAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Back to List").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                Text(email.headers["Subject"] ?? "(No Subject)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Spacer()

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

    private var forensicStatusBar: some View {
        let dashboard = reviewManager.computeDashboard(emails: emails)
        let filtered = filteredEmails.count
        let progressPct = Int(dashboard.progress * 100)

        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.small) {
                HStack(spacing: 4) {
                    ProgressView(value: dashboard.progress)
                        .frame(width: 80)
                        .tint(dashboard.progress >= 1.0 ? .green : .blue)
                    Text("\(dashboard.codedCount) of \(dashboard.totalEmails) reviewed (\(progressPct)%)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .help("Your review progress — tag emails using the Coding Panel or keyboard shortcuts to mark them as reviewed")

                Divider().frame(height: 12)

                HStack(spacing: 5) {
                    tagDot(.green, count: dashboard.tagDistribution[.relevant] ?? 0, label: "Relevant")
                    tagDot(.orange, count: dashboard.tagDistribution[.privileged] ?? 0, label: "Privileged")
                    tagDot(.red, count: dashboard.tagDistribution[.flagged] ?? 0, label: "Flagged")
                    tagDot(.gray, count: dashboard.tagDistribution[.irrelevant] ?? 0, label: "Irrelevant")
                    tagDot(.purple, count: dashboard.tagDistribution[.suspicious] ?? 0, label: "Suspicious")
                }
                .help("How your tagged emails are distributed across categories")

                if dashboard.privilegeFlagCount > 0 {
                    Divider().frame(height: 12)
                    HStack(spacing: 2) {
                        Image(systemName: "lock.shield").font(.system(size: 8)).foregroundColor(.orange)
                        Text("\(dashboard.privilegeFlagCount) privileged").font(.system(size: 9)).foregroundColor(.orange)
                    }
                    .help("Emails detected as potentially attorney-client privileged or legally protected")
                }

                if dashboard.codingVelocity > 0 {
                    Divider().frame(height: 12)
                    Text(String(format: "Speed: %.1f emails/min", dashboard.codingVelocity))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.blue)
                        .help("How fast you're reviewing — your average tagging rate this session")
                    if dashboard.estimatedCompletionMinutes > 0 && dashboard.estimatedCompletionMinutes < 10000 {
                        Text(String(format: "~%.0f min left", dashboard.estimatedCompletionMinutes))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .help("Estimated time to finish reviewing all remaining emails at your current pace")
                    }
                }

                Spacer()

                if filtered != emails.count {
                    Text("Showing \(filtered) of \(emails.count)")
                        .font(.system(size: 9)).foregroundColor(.blue)
                        .help("Filters are active — not all emails are shown. Clear filters to see everything.")
                }

                if reviewManager.reviewQueueMode {
                    HStack(spacing: 3) {
                        Image(systemName: "play.circle.fill").font(.system(size: 9)).foregroundColor(.green)
                        Text("Queue Mode").font(.system(size: 9, weight: .medium)).foregroundColor(.green)
                    }
                    .help("Queue mode auto-advances to the next unreviewed email after you tag one")
                }

                if !qcSampleIDs.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "dice").font(.system(size: 8))
                        Text("\(qcSampleIDs.count) QC samples").font(.system(size: 9))
                    }
                    .help("Quality control sample — a random set of emails selected for review accuracy checking")
                    .foregroundColor(.blue)
                    Button("Clear") { qcSampleIDs = [] }
                        .font(.system(size: 8)).buttonStyle(.plain).foregroundColor(.red)
                }
            }
            .padding(.horizontal, Spacing.small).padding(.vertical, 4)
            .background(AppColors.backgroundSecondary.opacity(0.3))
        }
    }

    private func tagDot(_ color: Color, count: Int, label: String) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)").font(.system(size: 8, weight: .bold, design: .monospaced))
            Text(label).font(.system(size: 7))
        }
        .foregroundColor(count > 0 ? color : .secondary.opacity(0.5))
    }

    // MARK: - Dashboard Sheet

    private var dashboardSheet: some View {
        let dashboard = reviewManager.computeDashboard(emails: emails)
        return ScrollView {
        VStack(spacing: 16) {
            HStack {
                Text("Review Dashboard").font(.title3).fontWeight(.bold)
                Spacer()
                Button("Done") { showDashboard = false }
            }

            HStack(spacing: 20) {
                dashboardStat("Total", value: "\(dashboard.totalEmails)", color: .primary)
                dashboardStat("Coded", value: "\(dashboard.codedCount)", color: .blue)
                dashboardStat("Remaining", value: "\(dashboard.totalEmails - dashboard.codedCount)", color: .orange)
                dashboardStat("Progress", value: String(format: "%.0f%%", dashboard.progress * 100), color: .green)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Tag Distribution").font(.headline)
                ForEach(ForensicManager.EvidenceTag.allCases.filter { $0 != .none }, id: \.self) { tag in
                    let count = dashboard.tagDistribution[tag] ?? 0
                    let pct = dashboard.totalEmails > 0 ? Double(count) / Double(dashboard.totalEmails) : 0
                    HStack {
                        Image(systemName: tag.icon).foregroundColor(tag.color).frame(width: 20)
                        Text(tag.rawValue).font(.system(size: 12)).frame(width: 80, alignment: .leading)
                        ProgressView(value: pct).frame(width: 120).tint(tag.color)
                        Text("\(count)").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 40, alignment: .trailing)
                        Text(String(format: "%.1f%%", pct * 100)).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Divider()

            HStack(spacing: 20) {
                if dashboard.codingVelocity > 0 {
                    dashboardStat("Speed", value: String(format: "%.1f/min", dashboard.codingVelocity), color: .blue)
                }
                if dashboard.estimatedCompletionMinutes > 0 && dashboard.estimatedCompletionMinutes < 10000 {
                    dashboardStat("ETA", value: String(format: "%.0f min", dashboard.estimatedCompletionMinutes), color: .orange)
                }
                dashboardStat("Priv Flags", value: "\(dashboard.privilegeFlagCount)", color: .orange)
                dashboardStat("Hot Folders", value: "\(reviewManager.hotFolders.count)", color: .red)
                dashboardStat("Productions", value: "\(reviewManager.productionSets.count)", color: .purple)
            }

            if hasForensicAnalysis {
                Divider()
                evidenceClustersSection
                Divider()
                forensicTimelineSection
            }

            Spacer()
        }
        .padding(20)
        }
        .frame(width: 500)
        .frame(minHeight: 450)
    }

    private func dashboardStat(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: - Production Sets Sheet

    private var productionSetsSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Production Sets").font(.title3).fontWeight(.bold)
                Spacer()
                Button("Done") { showProductionSets = false }
            }

            if reviewManager.productionSets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox").font(.largeTitle).foregroundColor(.secondary.opacity(0.3))
                    Text("No production sets").foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(reviewManager.productionSets) { prod in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: prod.status.icon).foregroundColor(prod.status.color)
                                Text(prod.name).font(.headline)
                                Spacer()
                                Menu(prod.status.rawValue) {
                                    ForEach(ForensicReviewManager.ProductionStatus.allCases, id: \.self) { status in
                                        Button(status.rawValue) {
                                            reviewManager.updateProductionStatus(prod.id, status: status)
                                        }
                                    }
                                }
                                .font(.system(size: 11))
                            }
                            HStack {
                                Text("\(prod.emailCount) documents").font(.system(size: 11)).foregroundColor(.secondary)
                                Text(prod.batesRange()).font(.system(size: 10, design: .monospaced)).foregroundColor(.purple)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            reviewManager.deleteProductionSet(reviewManager.productionSets[i].id)
                        }
                    }
                }
            }

            HStack {
                TextField("Name", text: $newProdName).textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("Prefix", text: $newProdPrefix).textFieldStyle(.roundedBorder).frame(width: 80)
                Button("Create") {
                    if !newProdName.isEmpty {
                        reviewManager.createProductionSet(name: newProdName, prefix: newProdPrefix)
                        newProdName = ""
                    }
                }
                .disabled(newProdName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }

    // MARK: - Review Queue

    private func startQueueReview() {
        reviewManager.startReviewQueue()
        let unreviewed = filteredEmails.filter { forensicManager.tagForEmail($0.id) == .none }
        if let first = unreviewed.first {
            selectedEmailIDs = [first.id]
        }
    }

    // MARK: - Helpers

    private func tagAndAdvance(_ tag: ForensicManager.EvidenceTag, in emails: [MBOXParser.RawEmail]) {
        if selectedEmailIDs.count > 1 {
            for id in selectedEmailIDs { forensicManager.tag(id, as: tag) }
        } else if let id = selectedEmailIDs.first {
            forensicManager.tag(id, as: tag)
            if let currentIndex = emails.firstIndex(where: { $0.id == id }) {
                let nextUnreviewed = emails[(currentIndex + 1)...].first { forensicManager.tagForEmail($0.id) == .none }
                    ?? emails.first { forensicManager.tagForEmail($0.id) == .none }
                if let next = nextUnreviewed {
                    selectedEmailIDs = [next.id]
                }
            }
        }
    }

    private func riskColor(_ score: Int) -> Color {
        if score >= 80 { return .red }
        if score >= 55 { return .orange }
        if score >= 30 { return .yellow }
        if score >= 10 { return .blue }
        return .green
    }

    static func formatDate(_ raw: String?) -> String {
        guard let raw, let date = MBOXParser.parseDate(raw) else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy"
        return f.string(from: date)
    }

    // MARK: - Forensic Analysis Features Loading

    private func loadForensicFeatures() async {
        guard !hasForensicAnalysis else { return }
        let emailsCopy = emails

        guard AnalysisCoordinator.isEnabled else {
            let scores = ForensicAnalysisFeatures.scoreEvidenceRelevance(emails: emailsCopy)
            let timeline = ForensicAnalysisFeatures.reconstructTimeline(emails: emailsCopy)
            let patterns = ForensicAnalysisFeatures.detectSuspiciousPatterns(in: emailsCopy)
            let clusters = ForensicAnalysisFeatures.clusterEvidence(emails: emailsCopy)
            let anomalies = ForensicAnalysisFeatures.detectMetadataAnomalies(in: emailsCopy)
            evidenceScores = Dictionary(uniqueKeysWithValues: scores.map { ($0.id, $0) })
            forensicTimeline = timeline; suspiciousPatterns = patterns
            evidenceClusters = clusters; metadataAnomalies = anomalies
            hasForensicAnalysis = true; return
        }

        coordinator.begin(steps: 5, color: .orange)

        coordinator.advance(step: 1, label: "Scoring evidence relevance...")
        guard let scores = await coordinator.runDetached({ ForensicAnalysisFeatures.scoreEvidenceRelevance(emails: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 2, label: "Reconstructing forensic timeline...")
        guard let timeline = await coordinator.runDetached({ ForensicAnalysisFeatures.reconstructTimeline(emails: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 3, label: "Detecting suspicious patterns...")
        guard let patterns = await coordinator.runDetached({ ForensicAnalysisFeatures.detectSuspiciousPatterns(in: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 4, label: "Clustering evidence...")
        guard let clusters = await coordinator.runDetached({ ForensicAnalysisFeatures.clusterEvidence(emails: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 5, label: "Checking metadata anomalies...")
        guard let anomalies = await coordinator.runDetached({ ForensicAnalysisFeatures.detectMetadataAnomalies(in: emailsCopy) }) else { coordinator.finish(); return }

        evidenceScores = Dictionary(uniqueKeysWithValues: scores.map { ($0.id, $0) })
        forensicTimeline = timeline
        suspiciousPatterns = patterns
        evidenceClusters = clusters
        metadataAnomalies = anomalies
        hasForensicAnalysis = true
        coordinator.finish()
    }

    // MARK: - Evidence Relevance Badge

    private func evidenceRelevanceBadge(for emailID: UUID) -> some View {
        Group {
            if let score = evidenceScores[emailID] {
                Circle()
                    .fill(relevanceLevelColor(score.relevanceLevel))
                    .frame(width: 8, height: 8)
                    .help("Relevance: \(score.relevanceLevel.rawValue) (\(String(format: "%.0f%%", score.score * 100)))")
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func relevanceLevelColor(_ level: ForensicAnalysisFeatures.EvidenceRelevanceScore.RelevanceLevel) -> Color {
        switch level {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .irrelevant: return .gray
        }
    }

    // MARK: - Suspicious Patterns Section (Coding Panel)

    private var suspiciousPatternsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(.orange)
                Text("Suspicious Patterns").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if !suspiciousPatterns.isEmpty {
                    Text("\(suspiciousPatterns.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(.orange))
                }
            }

            if suspiciousPatterns.isEmpty {
                Text("No suspicious patterns detected").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                ForEach(suspiciousPatterns.prefix(5)) { pattern in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(pattern.patternType.rawValue)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(patternSeverityColor(pattern.severity))
                            Spacer()
                            ProgressView(value: pattern.severity)
                                .frame(width: 40)
                                .tint(patternSeverityColor(pattern.severity))
                            Text(String(format: "%.0f%%", pattern.severity * 100))
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(patternSeverityColor(pattern.severity))
                                .help("Evidence relevance to case keywords and custodians, scored by NLP analysis")
                        }
                        Text(pattern.description)
                            .font(.system(size: 9))
                            .foregroundColor(.primary.opacity(0.8))
                            .lineLimit(2)
                        ForEach(pattern.indicators.prefix(3), id: \.self) { indicator in
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.right.circle").font(.system(size: 7)).foregroundColor(.secondary)
                                Text(indicator).font(.system(size: 8)).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(patternSeverityColor(pattern.severity).opacity(0.06)))
                }
            }
        }
    }

    private func patternSeverityColor(_ severity: Double) -> Color {
        if severity >= 0.7 { return .red }
        if severity >= 0.4 { return .orange }
        return .yellow
    }

    // MARK: - Metadata Anomaly Section (Coding Panel)

    private func metadataAnomalySection(email: MBOXParser.RawEmail) -> some View {
        let emailAnomalies = metadataAnomalies.filter { $0.email.id == email.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.badge.gearshape").font(.system(size: 10)).foregroundColor(.purple)
                Text("Metadata Anomalies").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if !emailAnomalies.isEmpty {
                    Text("\(emailAnomalies.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(.purple))
                }
            }

            if emailAnomalies.isEmpty {
                Text("No metadata anomalies for this email").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                ForEach(emailAnomalies) { anomaly in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: anomalyTypeIcon(anomaly.anomalyType))
                                .font(.system(size: 9))
                                .foregroundColor(patternSeverityColor(anomaly.severity))
                            Text(anomaly.anomalyType.rawValue)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(patternSeverityColor(anomaly.severity))
                            Spacer()
                            Text(String(format: "%.0f%%", anomaly.severity * 100))
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(patternSeverityColor(anomaly.severity))
                                .help("Evidence relevance to case keywords and custodians, scored by NLP analysis")
                        }
                        Text(anomaly.detail)
                            .font(.system(size: 9))
                            .foregroundColor(.primary.opacity(0.8))
                            .lineLimit(2)
                        HStack(spacing: 3) {
                            Image(systemName: "magnifyingglass").font(.system(size: 7)).foregroundColor(.purple)
                            Text(anomaly.forensicSignificance)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.purple.opacity(0.8))
                                .lineLimit(2)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.06)))
                }
            }
        }
    }

    private func anomalyTypeIcon(_ type: ForensicAnalysisFeatures.MetadataAnomaly.MetadataAnomalyType) -> String {
        switch type {
        case .timezoneInconsistency: return "clock.badge.exclamationmark"
        case .missingMessageID: return "number.circle"
        case .forgedHeaders: return "exclamationmark.shield"
        case .mismatchedDates: return "calendar.badge.exclamationmark"
        case .suspiciousXHeaders: return "xmark.octagon"
        case .strippedHeaders: return "scissors"
        case .encodingAnomaly: return "textformat.abc.dottedunderline"
        }
    }

    // MARK: - Evidence Clusters Section (Dashboard)

    private var evidenceClustersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evidence Clusters").font(.headline)

            if evidenceClusters.isEmpty {
                Text("No clusters identified").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(evidenceClusters.prefix(8)) { cluster in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cluster.topic)
                                .font(.system(size: 12, weight: .semibold))
                            HStack(spacing: 6) {
                                HStack(spacing: 2) {
                                    Image(systemName: "envelope").font(.system(size: 9))
                                    Text("\(cluster.emails.count) emails").font(.system(size: 10))
                                }
                                .foregroundColor(.blue)
                                HStack(spacing: 2) {
                                    Image(systemName: "person.2").font(.system(size: 9))
                                    Text("\(cluster.participants.count)").font(.system(size: 10))
                                }
                                .foregroundColor(.secondary)
                            }
                            if !cluster.keyTerms.isEmpty {
                                Text(cluster.keyTerms.joined(separator: ", "))
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.0f%%", cluster.cohesionScore * 100))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(cluster.cohesionScore >= 0.7 ? .green : (cluster.cohesionScore >= 0.4 ? .orange : .red))
                            Text("Cohesion")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(AppColors.backgroundSecondary.opacity(0.5)))
                }
            }
        }
    }

    // MARK: - Forensic Timeline Section (Dashboard)

    private var forensicTimelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Forensic Timeline").font(.headline)

            if forensicTimeline.isEmpty {
                Text("No timeline events").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                let dateFormatter: DateFormatter = {
                    let f = DateFormatter()
                    f.dateFormat = "MM/dd/yy HH:mm"
                    return f
                }()

                ForEach(forensicTimeline.prefix(12)) { event in
                    HStack(spacing: 8) {
                        Image(systemName: timelineEventIcon(event.eventType))
                            .font(.system(size: 12))
                            .foregroundColor(timelineEventColor(event.eventType))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(event.eventType.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(timelineEventColor(event.eventType))
                                Spacer()
                                Text(dateFormatter.string(from: event.timestamp))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Text(event.summary)
                                .font(.system(size: 10))
                                .foregroundColor(.primary.opacity(0.85))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                ProgressView(value: event.evidenceStrength)
                                    .frame(width: 50)
                                    .tint(timelineEventColor(event.eventType))
                                Text(String(format: "Strength: %.0f%%", event.evidenceStrength * 100))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .help("Evidence relevance to case keywords and custodians, scored by NLP analysis")
                                if !event.participants.isEmpty {
                                    Text("\(event.participants.count) participants")
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(timelineEventColor(event.eventType).opacity(0.05)))
                }
            }
        }
    }

    private func timelineEventIcon(_ type: ForensicAnalysisFeatures.ForensicTimelineEvent.ForensicEventType) -> String {
        switch type {
        case .communication: return "envelope"
        case .evidenceCreation: return "doc.badge.plus"
        case .deletionGap: return "exclamationmark.triangle"
        case .patternChange: return "waveform.path.ecg"
        case .spoofingAttempt: return "person.badge.shield.checkmark"
        case .piiExposure: return "eye.trianglebadge.exclamationmark"
        case .attachmentTransfer: return "paperclip"
        }
    }

    private func timelineEventColor(_ type: ForensicAnalysisFeatures.ForensicTimelineEvent.ForensicEventType) -> Color {
        switch type {
        case .communication: return .blue
        case .evidenceCreation: return .green
        case .deletionGap: return .red
        case .patternChange: return .orange
        case .spoofingAttempt: return .purple
        case .piiExposure: return .red
        case .attachmentTransfer: return .teal
        }
    }
}
