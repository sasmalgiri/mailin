import SwiftUI

struct DuplicateManagerView: View {
    @ObservedObject var model: ParsedEmailListViewModel
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss
    @State private var duplicateGroups: [[MBOXParser.RawEmail]] = []
    @State private var nearDuplicateGroups: [[MBOXParser.RawEmail]] = []
    @State private var selectedForRemoval: Set<UUID> = []
    @State private var isScanning = false
    @State private var showNearDuplicates = false
    @State private var similarityThreshold: Double = 0.85
    @State private var legalHoldWarning: String?
    @State private var showTutorial = false
    @State private var isRemoving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isScanning {
                scanningView
            } else if duplicateGroups.isEmpty && nearDuplicateGroups.isEmpty {
                emptyView
            } else {
                resultsList
            }
            Divider()
            actionBar
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 700, minHeight: 360, idealHeight: 600)
        #endif
        .onAppear { scanForDuplicates() }
        .featureTutorial(.duplicateManager, key: "duplicate_manager_tutorial_seen", isPresented: $showTutorial)
        .alert("Legal Hold", isPresented: Binding(
            get: { legalHoldWarning != nil },
            set: { if !$0 { legalHoldWarning = nil } }
        )) {
            Button("OK") { legalHoldWarning = nil }
        } message: {
            Text(legalHoldWarning ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: Spacing.small) {
            HStack {
                Label("Duplicate Manager", systemImage: "doc.on.doc")
                    .font(Typography.title3)
                    .fontWeight(.bold)
                Spacer()
                TutorialHelpButton(showTutorial: $showTutorial)
            }

            Toggle("Include near-duplicates", isOn: $showNearDuplicates)
                .font(Typography.callout)
                .onChange(of: showNearDuplicates) { _, _ in scanForDuplicates() }

            if showNearDuplicates {
                #if os(iOS)
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text("Similarity: \(Int(similarityThreshold * 100))%")
                        .font(Typography.caption1)
                    Slider(value: $similarityThreshold, in: 0.7...0.99, step: 0.01)
                        .accessibilityLabel("Similarity threshold")
                        .accessibilityValue("\(Int(similarityThreshold * 100)) percent")
                }
                #else
                HStack {
                    Text("Similarity: \(Int(similarityThreshold * 100))%")
                        .font(Typography.caption1)
                    Slider(value: $similarityThreshold, in: 0.7...0.99, step: 0.01)
                        .frame(maxWidth: 200)
                        .accessibilityLabel("Similarity threshold")
                        .accessibilityValue("\(Int(similarityThreshold * 100)) percent")
                }
                #endif
            }
        }
        .padding(Spacing.medium)
    }

    private var scanningView: some View {
        VStack(spacing: Spacing.medium) {
            ProgressView()
                .accessibilityLabel("Scanning for duplicates")
            Text("Scanning for duplicates...")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundColor(AppColors.success)
                .accessibilityHidden(true)
            Text("No duplicates found")
                .font(Typography.headline)
            Text("Your email archive has no duplicate messages.")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No duplicates found. Your email archive has no duplicate messages.")
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                archiveWideDedupCard

                bulkSelectBar

                if !duplicateGroups.isEmpty {
                    Text("Exact Duplicates (\(duplicateGroups.count) groups)")
                        .font(Typography.headline)
                        .padding(.horizontal, Spacing.medium)

                    Label {
                        Text("Exact duplicates have identical content (subject, body, and headers). Removing duplicates reduces archive size without losing information.")
                            .font(Typography.caption1)
                    } icon: {
                        Image(systemName: "doc.on.doc.fill")
                            .foregroundColor(.blue)
                    }
                    .padding(Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                    .padding(.horizontal, Spacing.medium)

                    ForEach(Array(duplicateGroups.enumerated()), id: \.offset) { _, group in
                        duplicateGroupView(group, isExact: true)
                    }
                }

                if showNearDuplicates && !nearDuplicateGroups.isEmpty {
                    Text("Near Duplicates (\(nearDuplicateGroups.count) groups)")
                        .font(Typography.headline)
                        .padding(.horizontal, Spacing.medium)
                        .padding(.top, Spacing.small)

                    Label {
                        Text("Near duplicates share similar content but may differ in forwarding headers, signatures, or minor edits. Review before removing to avoid losing unique information.")
                            .font(Typography.caption1)
                    } icon: {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.orange)
                    }
                    .padding(Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                    .padding(.horizontal, Spacing.medium)

                    ForEach(Array(nearDuplicateGroups.enumerated()), id: \.offset) { _, group in
                        duplicateGroupView(group, isExact: false)
                    }
                }
            }
            .padding(Spacing.medium)
        }
    }

    /// The count of redundant copies across every currently-shown group
    /// (all copies except the one kept per group).
    private var redundantCount: Int {
        var n = duplicateGroups.reduce(0) { $0 + max(0, $1.count - 1) }
        if showNearDuplicates {
            n += nearDuplicateGroups.reduce(0) { $0 + max(0, $1.count - 1) }
        }
        return n
    }

    /// One click to select every redundant copy across ALL groups — so a
    /// user facing hundreds of groups doesn't click each one.
    private func selectAllButFirstEverywhere() {
        for group in duplicateGroups {
            for email in group.dropFirst() { selectedForRemoval.insert(email.id) }
        }
        if showNearDuplicates {
            for group in nearDuplicateGroups {
                for email in group.dropFirst() { selectedForRemoval.insert(email.id) }
            }
        }
    }

    private var bulkSelectBar: some View {
        HStack(spacing: Spacing.small) {
            Button {
                selectAllButFirstEverywhere()
            } label: {
                Label("Select all but first (all groups)", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(redundantCount == 0)
            .help("Selects every redundant copy across all \(duplicateGroups.count + (showNearDuplicates ? nearDuplicateGroups.count : 0)) groups, keeping one of each — then press Remove Selected")

            if !selectedForRemoval.isEmpty {
                Button {
                    selectedForRemoval.removeAll()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
            Text("\(redundantCount) removable")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.horizontal, Spacing.medium)
    }

    private func duplicateGroupView(_ group: [MBOXParser.RawEmail], isExact: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack {
                Image(systemName: isExact ? "doc.on.doc.fill" : "doc.on.doc")
                    .foregroundColor(isExact ? AppColors.error : .orange)
                    .accessibilityHidden(true)
                Text(group.first?.headers["Subject"] ?? "(No Subject)")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text("\(group.count) copies")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                Button("Select All But First") {
                    for email in group.dropFirst() {
                        selectedForRemoval.insert(email.id)
                    }
                }
                .font(Typography.caption2)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Select all but first copy for removal")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isExact ? "Exact" : "Near") duplicate group: \(group.first?.headers["Subject"] ?? "No Subject"), \(group.count) copies")

            ForEach(group) { email in
                HStack(spacing: Spacing.xSmall) {
                    Toggle("", isOn: Binding(
                        get: { selectedForRemoval.contains(email.id) },
                        set: { if $0 { selectedForRemoval.insert(email.id) } else { selectedForRemoval.remove(email.id) } }
                    ))
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 1) {
                        Text(email.headers["From"] ?? "")
                            .font(Typography.caption1)
                            .lineLimit(1)
                        Text(email.timestamp)
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                    Spacer()
                }
                .padding(.leading, Spacing.large)
            }
        }
        .padding(Spacing.small)
        .background(AppColors.backgroundSecondary)
        .cornerRadius(CornerRadius.medium)
    }

    private var actionBar: some View {
        HStack {
            Text("\(selectedForRemoval.count) selected for removal")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
                .accessibilityLabel("\(selectedForRemoval.count) emails selected for removal")
            Spacer()
            Button("Cancel") { closeSheet() }
                .buttonStyle(.bordered)
                .disabled(isRemoving)
            Button {
                removeSelected()
            } label: {
                if isRemoving {
                    HStack(spacing: Spacing.xxSmall) { ProgressView().controlSize(.small); Text("Removing…") }
                } else {
                    Text("Remove Selected")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.error)
            .disabled(selectedForRemoval.isEmpty || isRemoving)
            .accessibilityLabel("Remove \(selectedForRemoval.count) selected emails")
            .accessibilityHint("Permanently removes selected duplicate emails")
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    /// Remove the ticked copies. Awaits the delete fully, updates the in-memory
    /// groups, and only THEN dismisses — never dismiss while the async delete's
    /// refresh is still landing (that races window teardown and quit the app).
    private func removeSelected() {
        let (allowed, blocked) = CustodianManager.shared.filterProtected(selectedForRemoval)
        guard !allowed.isEmpty else {
            if !blocked.isEmpty {
                legalHoldWarning = "\(blocked.count) email(s) skipped — under legal hold with evidence seal."
            }
            return
        }
        isRemoving = true
        Task { @MainActor in
            let ok = await model.removeDuplicateEmailsAwaiting(ids: allowed)
            if ok { stripRemoved(allowed) }
            isRemoving = false
            if !blocked.isEmpty {
                // Keep the window open so the user sees why some were kept.
                legalHoldWarning = "\(blocked.count) email(s) skipped — under legal hold with evidence seal."
                return
            }
            if ok { closeSheet() }
        }
    }

    /// Drop the removed ids from the shown groups and the selection so the view
    /// stays consistent whether or not it closes. Groups that fall to a single
    /// copy are no longer duplicates and disappear.
    private func stripRemoved(_ ids: Set<UUID>) {
        duplicateGroups = duplicateGroups
            .map { $0.filter { !ids.contains($0.id) } }
            .filter { $0.count > 1 }
        nearDuplicateGroups = nearDuplicateGroups
            .map { $0.filter { !ids.contains($0.id) } }
            .filter { $0.count > 1 }
        selectedForRemoval.subtract(ids)
    }

    @State private var archiveDupIDs: [UUID] = []
    @State private var archiveDupChecked = false
    @State private var showArchiveDedupConfirm = false

    /// Archive-wide exact dedup — one click, SQL over the WHOLE store (the
    /// group list below is window-bounded). Keeps the best copy per
    /// Message-ID (source-identified over migrated, then earliest import).
    private var archiveWideDedupCard: some View {
        Group {
            if archiveDupChecked && !archiveDupIDs.isEmpty {
                HStack(spacing: Spacing.small) {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(archiveDupIDs.count) exact duplicate\(archiveDupIDs.count == 1 ? "" : "s") across the whole archive")
                            .font(Typography.callout)
                            .fontWeight(.semibold)
                        Text("Same Message-ID stored more than once — typically a migrated archive plus a fresh import of the original file. One copy of each email is kept (the full-fidelity one).")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                    Spacer()
                    Button {
                        showArchiveDedupConfirm = true
                    } label: {
                        Label("Remove All", systemImage: "trash")
                    }
                    .help("Delete every redundant copy in one step — each email keeps exactly one row")
                }
                .padding(Spacing.small)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(CornerRadius.small)
                .padding(.horizontal, Spacing.medium)
                .adaptiveDestructiveConfirmation(
                    "Remove \(archiveDupIDs.count) Duplicates",
                    isPresented: $showArchiveDedupConfirm,
                    message: "Every email keeps exactly one copy — \(archiveDupIDs.count) redundant row\(archiveDupIDs.count == 1 ? "" : "s") will be deleted. Review state on the removed copies is discarded.",
                    actionTitle: "Remove Duplicates"
                ) {
                    let ids = Set(archiveDupIDs)
                    archiveDupIDs = []
                    isRemoving = true
                    Task { @MainActor in
                        _ = await DocumentRegistry.post(
                            .cleanup, summary: "Removed \(ids.count) exact duplicate(s) archive-wide")
                        _ = await model.removeDuplicateEmailsAwaiting(ids: ids)
                        stripRemoved(ids)
                        isRemoving = false
                    }
                }
            }
        }
        .task {
            guard !archiveDupChecked else { return }
            archiveDupIDs = (try? await SQLiteEmailStore.shared.exactMessageIDDuplicateIDs()) ?? []
            archiveDupChecked = true
        }
    }

    private func scanForDuplicates() {
        isScanning = true
        let includeNear = showNearDuplicates
        let threshold = similarityThreshold

        Task.detached(priority: .utility) {
            // v2: scan a bounded working set from the store (the store already
            // enforces message-id dedup at insert; this surfaces near-dupes and
            // content-hash groups over a bounded window).
            var emails: [MBOXParser.RawEmail] = []
            let stream = await ArchiveDataService.shared.streamFullEmails(query: .all, batchSize: 200)
            do { for try await b in stream { emails.append(contentsOf: b); if emails.count >= 5000 { break } } } catch { }
            emails = Array(emails.prefix(5000))
            let exactGroups = Self.findExactDuplicates(in: emails)
            let nearGroups: [[MBOXParser.RawEmail]]
            if includeNear {
                nearGroups = Self.findNearDuplicates(in: emails, threshold: threshold)
            } else {
                nearGroups = []
            }

            await MainActor.run {
                self.duplicateGroups = exactGroups
                self.nearDuplicateGroups = nearGroups
                self.isScanning = false
            }
        }
    }

    nonisolated static func findExactDuplicates(in emails: [MBOXParser.RawEmail]) -> [[MBOXParser.RawEmail]] {
        var byMessageID: [String: [MBOXParser.RawEmail]] = [:]
        var byHash: [String: [MBOXParser.RawEmail]] = [:]

        for email in emails {
            if let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"], !msgID.isEmpty {
                byMessageID[msgID, default: []].append(email)
            }
            let hash = MBOXParser.sha1(
                (email.headers["From"] ?? "") +
                (email.headers["Subject"] ?? "") +
                (email.headers["Date"] ?? "") +
                String(email.plainBody.prefix(200))
            )
            byHash[hash, default: []].append(email)
        }

        var groups: [[MBOXParser.RawEmail]] = []
        var seen = Set<UUID>()
        for (_, group) in byMessageID where group.count > 1 {
            let ids = group.map(\.id)
            if !ids.contains(where: { seen.contains($0) }) {
                groups.append(group)
                seen.formUnion(ids)
            }
        }
        for (_, group) in byHash where group.count > 1 {
            let ids = group.map(\.id)
            if !ids.contains(where: { seen.contains($0) }) {
                groups.append(group)
                seen.formUnion(ids)
            }
        }
        return groups.sorted { $0.count > $1.count }
    }

    nonisolated private static func findNearDuplicates(in emails: [MBOXParser.RawEmail], threshold: Double) -> [[MBOXParser.RawEmail]] {
        let bySender = Dictionary(grouping: emails, by: { $0.headers["From"] ?? "" })
        var groups: [[MBOXParser.RawEmail]] = []

        for (_, senderEmails) in bySender where senderEmails.count > 1 {
            var processed = Set<UUID>()
            for i in 0..<senderEmails.count {
                guard !processed.contains(senderEmails[i].id) else { continue }
                var group = [senderEmails[i]]
                for j in (i+1)..<senderEmails.count {
                    guard !processed.contains(senderEmails[j].id) else { continue }
                    let sim = jaccardSimilarity(
                        Set(senderEmails[i].plainBody.lowercased().split(separator: " ").map(String.init)),
                        Set(senderEmails[j].plainBody.lowercased().split(separator: " ").map(String.init))
                    )
                    if sim >= threshold {
                        group.append(senderEmails[j])
                        processed.insert(senderEmails[j].id)
                    }
                }
                if group.count > 1 {
                    processed.insert(senderEmails[i].id)
                    groups.append(group)
                }
            }
        }
        return groups.sorted { $0.count > $1.count }
    }

    nonisolated private static func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }
}
