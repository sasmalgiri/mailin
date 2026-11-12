@testable import ArchiveCore
import SwiftUI

struct DuplicateManagerView: View {
    @ObservedObject var model: ParsedEmailListViewModel
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss
    // Five jobs DUP-01: engine groups are compared in full before they are
    // shown. Verified groups may be removed in bulk; candidates are decided
    // one copy at a time.
    @State private var verifiedGroups: [DuplicateVerification.Group] = []
    @State private var candidateGroups: [DuplicateVerification.Group] = []
    /// DUP-05: the pair being compared side by side.
    @State private var comparing: ComparePair?
    struct ComparePair: Identifiable { let id = UUID(); let a: MBOXParser.RawEmail; let b: MBOXParser.RawEmail }
    @State private var nearDuplicateGroups: [[MBOXParser.RawEmail]] = []
    @State private var selectedForRemoval: Set<UUID> = []
    @State private var isScanning = false
    @State private var showNearDuplicates = false
    @State private var similarityThreshold: Double = 0.85
    @State private var legalHoldWarning: String?
    @State private var showTutorial = false
    @State private var isRemoving = false
    // §3-L19: whole-archive exact groups when the 3.0 engine is on.
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    @State private var v3Note: String?
    private var v3: Bool { modules?.isOn(.v3Duplicates) ?? false }
    /// IPAD-05 (c): how far the similar-message search reached, for the summary.
    @State private var nearCoverage: DuplicateSummary.NearCoverage = .notChecked

    private var summary: DuplicateSummary.Text {
        DuplicateSummary.text(verified: verifiedGroups.count, candidates: candidateGroups.count,
                              similar: showNearDuplicates ? nearDuplicateGroups.count : 0,
                              near: showNearDuplicates ? nearCoverage : .notChecked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isScanning {
                scanningView
            } else if verifiedGroups.isEmpty && candidateGroups.isEmpty && nearDuplicateGroups.isEmpty {
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
                .accessibilityIdentifier("duplicates.includeNear")
                .onChange(of: showNearDuplicates) { _, _ in scanForDuplicates() }
            if let v3Note {
                Text(v3Note)
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
            // The archive-wide Message-ID check lives on this card; without it
            // here an empty group list hid copies that check had found.
            archiveWideDedupCard
            VStack(spacing: Spacing.medium) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(AppColors.success)
                    .accessibilityHidden(true)
                // IPAD-05 (c): what was found AND what was checked — never "no
                // duplicate messages" while similar ones were not looked for.
                Text(summary.title)
                    .font(Typography.headline)
                Text(summary.detail)
                    .font(Typography.callout)
                    .foregroundColor(AppColors.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.medium)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("duplicates.summary.empty")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                archiveWideDedupCard

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(Typography.callout)
                        .fontWeight(.semibold)
                    Text(summary.detail)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                .padding(.horizontal, Spacing.medium)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("duplicates.summary")

                bulkSelectBar

                if !verifiedGroups.isEmpty {
                    Text("Verified identical (^[\(verifiedGroups.count) group](inflect: true))")
                        .font(Typography.headline)
                        .padding(.horizontal, Spacing.medium)

                    Label {
                        Text("Every copy in these groups was compared in full — the stored message bytes, or every address, the date, the subject, the whole body, the MIME structure and each attachment. Moving the extra copies to the Trash loses no message content: their folders, labels, tags and notes are merged into the kept copy, and the Trash restores them.")
                            .font(Typography.caption1)
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                    }
                    .padding(Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                    .padding(.horizontal, Spacing.medium)

                    ForEach(verifiedGroups) { group in
                        duplicateGroupView(group.members, kind: .verified(group.verdict))
                    }
                }

                if !candidateGroups.isEmpty {
                    Text("Candidates (^[\(candidateGroups.count) group](inflect: true))")
                        .font(Typography.headline)
                        .padding(.horizontal, Spacing.medium)
                        .padding(.top, Spacing.small)

                    Label {
                        Text("These share a Message-ID, an opening passage or a content hash but differ somewhere. They are not proven identical and are left out of bulk selection; tick a copy yourself only after comparing it.")
                            .font(Typography.caption1)
                    } icon: {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.orange)
                    }
                    .padding(Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                    .padding(.horizontal, Spacing.medium)

                    ForEach(candidateGroups) { group in
                        duplicateGroupView(group.members, kind: .candidate(group.verdict))
                        // DUP-05: the two copies side by side before anyone ticks one.
                        if group.members.count >= 2 {
                            Button {
                                comparing = ComparePair(a: group.members[0], b: group.members[1])
                            } label: { Label(String(localized: "Compare the first two copies side by side"), systemImage: "rectangle.split.2x1") }
                            .buttonStyle(.plain)
                            .font(Typography.caption1)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, Spacing.medium)
                            .accessibilityIdentifier("duplicates.compare.\(group.id.uuidString)")
                        }
                    }
                }

                if showNearDuplicates && !nearDuplicateGroups.isEmpty {
                    Text("Similar (^[\(nearDuplicateGroups.count) group](inflect: true))")
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
                        duplicateGroupView(group, kind: .near)
                    }
                }
            }
            .padding(Spacing.medium)
        }
        .sheet(item: $comparing) { pair in
            VStack(alignment: .trailing, spacing: Spacing.small) {
                EmailComparisonView(emailA: pair.a, emailB: pair.b)
                Button(String(localized: "Close")) { comparing = nil }.keyboardShortcut(.cancelAction).padding([.trailing, .bottom], Spacing.medium)
            }
            .frame(minWidth: 900, minHeight: 600)
        }
    }

    /// The copies a bulk selection may take: every copy after the first in
    /// each VERIFIED group. Candidates and near-duplicates are similar, not
    /// identical, so they never enter a bulk selection (DUP-01).
    private var bulkRemovable: [UUID] { DuplicateVerification.bulkRemovable(verifiedGroups) }

    private var redundantCount: Int { bulkRemovable.count }

    /// One click to select every extra copy in every verified group — so a
    /// user facing hundreds of groups doesn't click each one.
    private func selectAllButFirstEverywhere() {
        selectedForRemoval.formUnion(bulkRemovable)
    }

    private var bulkSelectBar: some View {
        HStack(spacing: Spacing.small) {
            Button {
                selectAllButFirstEverywhere()
            } label: {
                Label("Select all but first (verified groups)", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(redundantCount == 0)
            .accessibilityIdentifier("duplicates.selectAllVerified")
            .help(Inflect.string("Selects every extra copy in the ^[\(verifiedGroups.count) verified group](inflect: true), keeping one of each — then press Move Selected to Trash. Candidates and near-duplicates are never selected in bulk."))

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
            Text("^[\(redundantCount) copy](inflect: true) removable in verified groups")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.horizontal, Spacing.medium)
    }

    /// How a group was classified, which decides its badge and whether it
    /// offers "Select All But First".
    private enum GroupKind {
        case verified(DuplicateVerification.Verdict)
        case candidate(DuplicateVerification.Verdict)
        case near

        var allowsBulkSelect: Bool { if case .verified = self { return true } else { return false } }
        /// CLOSE-06: the group header's accessibility identifier suffix.
        var identifierKey: String {
            switch self {
            case .verified: return "verified"
            case .candidate: return "candidate"
            case .near: return "similar"
            }
        }
        var symbol: String {
            switch self {
            case .verified: return "checkmark.seal.fill"
            case .candidate: return "questionmark.circle"
            case .near: return "doc.on.doc"
            }
        }
        var tint: Color {
            switch self {
            case .verified: return AppColors.error
            case .candidate, .near: return .orange
            }
        }
        var name: String {
            switch self {
            case .verified(.byteIdentical): return String(localized: "Byte-identical")
            case .verified: return String(localized: "Content-equivalent")
            case .candidate: return String(localized: "Candidate")
            case .near: return String(localized: "Similar")
            }
        }
        /// The second line under a group's title, when there is something to say.
        var note: String? {
            switch self {
            case .verified(.contentEquivalent(attachmentBytesCompared: false)):
                // Not produced by verification any more (audit A01); an older stored verdict reads as unproven.
                return DuplicateVerification.contentEquivalentDefinition + " " + String(localized: "Attachment bytes were not compared for every copy — compare the files before removing.")
            case .verified(.contentEquivalent):
                return DuplicateVerification.contentEquivalentDefinition
            case .candidate(let verdict):
                return DuplicateVerification.differenceLine(verdict)
            case .near:
                return String(localized: "Similar text above the chosen threshold — not identical. Compare the copies before ticking one.")
            default:
                return nil
            }
        }
    }

    private func duplicateGroupView(_ group: [MBOXParser.RawEmail], kind: GroupKind) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack {
                Image(systemName: kind.symbol)
                    .foregroundColor(kind.tint)
                    .accessibilityHidden(true)
                Text(group.first?.headers["Subject"] ?? "(No Subject)")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text("^[\(group.count) copy](inflect: true)")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                if kind.allowsBulkSelect {
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
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Inflect.string("\(kind.name) duplicate group: \(group.first?.headers["Subject"] ?? String(localized: "No Subject")), ^[\(group.count) copy](inflect: true)"))
            .accessibilityIdentifier("duplicates.group.\(kind.identifierKey)")
            if let note = kind.note {
                Text(note)
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                    .padding(.leading, Spacing.large)
            }
            // DUP-05: the survivor preview — which copy stays and where it lives.
            Text("Kept: \(DuplicateVerification.survivorLine(group))")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .lineLimit(2)
                .padding(.leading, Spacing.large)
                .accessibilityIdentifier("duplicates.group.kept")

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

    /// DUP-05: what a later permanent deletion of the ticked copies would free.
    @State private var reclaimEstimate: Int64?

    private var actionBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(selectedForRemoval.count) copy](inflect: true) selected to move to the Trash")
                    .font(Typography.callout)
                    .foregroundColor(AppColors.secondary)
                    .accessibilityLabel(Inflect.string("^[\(selectedForRemoval.count) email](inflect: true) selected to move to the Trash"))
                    .accessibilityIdentifier("duplicates.selectedCount")
                if !selectedForRemoval.isEmpty, let reclaimEstimate {
                    Text("The Trash frees no space. Deleting these copies permanently later would free about \(ByteCountFormatter.string(fromByteCount: reclaimEstimate, countStyle: .file)).")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .accessibilityIdentifier("duplicates.reclaimEstimate")
                }
            }
            Spacer()
            Button("Cancel") { closeSheet() }
                .buttonStyle(.bordered)
                .disabled(isRemoving)
            Button {
                removeSelected()
            } label: {
                if isRemoving {
                    HStack(spacing: Spacing.xxSmall) { ProgressView().controlSize(.small); Text("Moving to the Trash…") }
                } else {
                    Text("Move Selected to Trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.error)
            .disabled(selectedForRemoval.isEmpty || isRemoving)
            .accessibilityLabel(Inflect.string("Move ^[\(selectedForRemoval.count) selected email](inflect: true) to the Trash"))
            .accessibilityHint("Moves the selected copies to the Trash, restorable; their folders, labels, tags and notes are merged into the kept copy")
            .accessibilityIdentifier("duplicates.moveSelected")
        }
        .padding(Spacing.medium)
        .task(id: selectedForRemoval) {
            guard !selectedForRemoval.isEmpty else { reclaimEstimate = nil; return }
            reclaimEstimate = try? await SQLiteEmailStore.shared.reclaimableBytesEstimate(ids: Array(selectedForRemoval))
        }
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    /// Every group on screen, as member lists, for survivor planning.
    private var allGroupsOnScreen: [[MBOXParser.RawEmail]] {
        verifiedGroups.map(\.members) + candidateGroups.map(\.members) + nearDuplicateGroups
    }

    /// DUP-04/05: merge each ticked copy into its group's survivor, then move
    /// it to the Trash (restorable). Awaits the store fully, updates the
    /// in-memory groups, records the receipt once it has happened, and only
    /// THEN dismisses — never while a refresh is still landing (that raced
    /// window teardown and quit the app).
    private func removeSelected() {
        let (allowed, blocked) = CustodianManager.shared.filterProtected(selectedForRemoval)
        guard !allowed.isEmpty else {
            if !blocked.isEmpty {
                legalHoldWarning = Inflect.string("^[\(blocked.count) email](inflect: true) skipped — under legal hold with evidence seal.")
            }
            return
        }
        isRemoving = true
        let plans = DuplicateVerification.plans(for: allowed, among: allGroupsOnScreen)
        Task { @MainActor in
            await applyPlans(plans, alsoBlocked: blocked.count, closeWhenDone: true)
        }
    }

    /// The one path every removal takes.
    private func applyPlans(_ plans: [SQLiteEmailStore.DuplicateRemovalPlan], alsoBlocked: Int, closeWhenDone: Bool) async {
        do {
            let result = try await SQLiteEmailStore.shared.removeDuplicateCopies(plans)
            model.invalidateSearchCache()
            await model.refreshFromStoreNow()
            if !result.trashed.isEmpty {
                // The receipt is written only after the change really happened.
                let number = await DocumentRegistry.post(.cleanup, summary: Self.receiptSummary(result))
                // v4.0 REC-02: a recipe step verifies the removal from this document.
                RecipeJobBroker.shared.report(.dedupe, outcome: number == nil ? .unverifiable : .succeeded,
                                              receipt: .init(kind: number == nil ? .none : .registryDocument, id: number ?? ""),
                                              summary: "\(number ?? "no receipt"): \(Self.receiptSummary(result))",
                                              count: result.trashed.count)
            }
            stripRemoved(Set(result.trashed))
            isRemoving = false
            if !result.trashed.isEmpty {
                // IPAD-05 (b): every count surface re-reads the store, and this
                // sheet scans again — its scope line and groups were the ones
                // from before the move ("All 51 emails processed" over 50).
                NotificationCenter.default.post(name: .archiveTrashChanged, object: nil)
                if !closeWhenDone {
                    await loadArchiveWide()
                    scanForDuplicates()
                }
            }
            let kept = alsoBlocked + result.heldKept.count
            if kept > 0 {
                // Keep the window open so the user sees why some were kept.
                legalHoldWarning = Inflect.string("^[\(kept) copy](inflect: true) kept — under legal hold. The rest were moved to the Trash.")
                return
            }
            if closeWhenDone { closeSheet() }
        } catch {
            isRemoving = false
            RecipeJobBroker.shared.report(.dedupe, outcome: .failed, receipt: .init(kind: .none, id: ""),
                                          summary: "Duplicate removal failed — nothing was changed: \(error.localizedDescription)")
            legalHoldWarning = String(localized: "The duplicates could not be moved to the Trash — nothing was changed. \(error.localizedDescription)")
        }
    }

    /// The durable record's one line (English, like every registry entry).
    static func receiptSummary(_ result: SQLiteEmailStore.DuplicateCleanupResult) -> String {
        var parts = ["Moved \(result.trashed.count) duplicate copies to the Trash (restorable)"]
        parts.append("merged into the kept copies: \(result.membershipsMerged) folder memberships, \(result.userTagsMerged) tags, \(result.annotationsMerged) notes")
        if !result.heldKept.isEmpty { parts.append("\(result.heldKept.count) held copies kept") }
        return parts.joined(separator: "; ")
    }

    /// Drop the removed ids from the shown groups and the selection so the view
    /// stays consistent whether or not it closes. Groups that fall to a single
    /// copy are no longer duplicates and disappear.
    private func stripRemoved(_ ids: Set<UUID>) {
        func strip(_ groups: [DuplicateVerification.Group]) -> [DuplicateVerification.Group] {
            groups.compactMap { group in
                var g = group
                g.members.removeAll { ids.contains($0.id) }
                return g.members.count > 1 ? g : nil
            }
        }
        verifiedGroups = strip(verifiedGroups)
        candidateGroups = strip(candidateGroups)
        nearDuplicateGroups = nearDuplicateGroups
            .map { $0.filter { !ids.contains($0.id) } }
            .filter { $0.count > 1 }
        selectedForRemoval.subtract(ids)
    }

    /// Archive-wide: the copies verified identical and safe to remove in one click.
    @State private var archiveRemovable: [UUID] = []
    /// Archive-wide: survivor per group, for the merge before the move.
    @State private var archivePlans: [SQLiteEmailStore.DuplicateRemovalPlan] = []
    /// Archive-wide: same-Message-ID groups whose content differed — never removed here.
    @State private var archiveCandidateGroups = 0
    @State private var archiveDupChecked = false
    @State private var showArchiveDedupConfirm = false

    /// Archive-wide dedup — one click, SQL over the WHOLE store. Same
    /// Message-ID groups are loaded a chunk at a time and compared in full
    /// (DUP-01); only verified copies are offered. Keeps the best copy per
    /// Message-ID (source-identified over migrated, then earliest import).
    private var archiveWideDedupCard: some View {
        // A view that is always there: `.task` on an empty Group never runs,
        // so the content it loads could never appear.
        VStack(alignment: .leading, spacing: 0) {
            if archiveDupChecked && (!archiveRemovable.isEmpty || archiveCandidateGroups > 0) {
                HStack(spacing: Spacing.small) {
                    Image(systemName: archiveRemovable.isEmpty ? "questionmark.circle" : "checkmark.seal.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        if !archiveRemovable.isEmpty {
                            Text("^[\(archiveRemovable.count) verified identical copy](inflect: true) across the whole archive")
                                .font(Typography.callout)
                                .fontWeight(.semibold)
                            Text("Same Message-ID stored more than once and compared in full — typically a migrated archive plus a fresh import of the original file. One copy of each email is kept (the full-fidelity one).")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }
                        if archiveCandidateGroups > 0 {
                            Text(Inflect.string("Sharing a Message-ID but differing in content: ^[\(archiveCandidateGroups) group](inflect: true), listed below as candidates and not removed here."))
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }
                    }
                    Spacer()
                    if !archiveRemovable.isEmpty {
                        Button {
                            showArchiveDedupConfirm = true
                        } label: {
                            Label("Move All to Trash", systemImage: "trash")
                        }
                        .help("Moves every verified extra copy to the Trash in one step (restorable); each email keeps exactly one copy, with every folder, label, tag and note merged into it")
                    }
                }
                .padding(Spacing.small)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(CornerRadius.small)
                .padding(.horizontal, Spacing.medium)
                .adaptiveDestructiveConfirmation(
                    Inflect.string("Move ^[\(archiveRemovable.count) Duplicate](inflect: true) to the Trash"),
                    isPresented: $showArchiveDedupConfirm,
                    message: Inflect.string("Every email keeps exactly one copy — ^[\(archiveRemovable.count) redundant copy](inflect: true) will move to the Trash, restorable from there. Folders, labels, tags and notes are merged into the kept copy first. The Trash frees no space until it is emptied."),
                    actionTitle: String(localized: "Move to Trash")
                ) {
                    // Held emails are never removed — the same protection the
                    // per-group removal applies, and the store checks its own
                    // holds again.
                    let (ids, blocked) = CustodianManager.shared.filterProtected(Set(archiveRemovable))
                    let plans = archivePlans.compactMap { plan -> SQLiteEmailStore.DuplicateRemovalPlan? in
                        let removed = plan.removed.filter { ids.contains($0) }
                        return removed.isEmpty ? nil : .init(survivor: plan.survivor, removed: removed)
                    }
                    isRemoving = true
                    Task { @MainActor in
                        await applyPlans(plans, alsoBlocked: blocked.count, closeWhenDone: false)
                        archiveRemovable = archiveRemovable.filter { id in blocked.contains(id) }
                    }
                }
            }
        }
        .task {
            guard !archiveDupChecked else { return }
            await loadArchiveWide()
        }
    }

    /// The archive-wide Message-ID groups, verified — also re-run after a move.
    private func loadArchiveWide() async {
        do {
            let store = SQLiteEmailStore.shared
            var groups = try await Self.withoutTrashed(try await store.messageIDDuplicateGroups(), store: store)
            // REC-05: opened from a recipe step, only copies inside the run's frozen selection are offered.
            if let frozen = RecipeFrozenScope.query(RecipeJobBroker.shared.waitingTicket(for: .dedupe)?.context.selection) {
                groups = try await RecipeFrozenScope.restrict(groups: groups, to: frozen, archive: .shared)
            }
            let result = try await DuplicateVerification.verifyArchiveWide(groups: groups) { ids in
                try await ArchiveDataService.shared.fullEmails(ids: ids)
            }
            archiveRemovable = result.removable
            archivePlans = result.plans
            archiveCandidateGroups = result.candidateGroups
            // v4.0 REC-02: a measured "nothing to remove" is a dedupe result;
            // groups whose content differed still need the person.
            if result.removable.isEmpty && result.candidateGroups == 0 {
                RecipeJobBroker.shared.report(.dedupe, outcome: .succeeded,
                                              receipt: .init(kind: .measurement, id: "0 verified duplicate copies archive-wide"),
                                              summary: "Checked archive-wide: 0 verified duplicate copies to remove", count: 0)
            }
        } catch {
            archiveRemovable = []
            archivePlans = []
            archiveCandidateGroups = 0
        }
        archiveDupChecked = true
    }

    /// IPAD-05 (b): a copy already in the Trash is not a duplicate to offer
    /// again. The store's Message-ID grouping reads every stored row, so
    /// without this a re-check after "Move All to Trash" offered the same
    /// copy a second time. Groups left with one copy are dropped.
    static func withoutTrashed(_ groups: [[EmailID]], store: SQLiteEmailStore) async throws -> [[EmailID]] {
        let ids = groups.flatMap { $0 }
        var trashed = Set<EmailID>()
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            for (id, state) in try await store.reviewStates(ids: chunk) where state.trashed { trashed.insert(id) }
            start += chunk.count
        }
        guard !trashed.isEmpty else { return groups }
        return groups.map { $0.filter { !trashed.contains($0) } }.filter { $0.count > 1 }
    }

    /// IPAD-05 (c): the whole-archive near-duplicate engine's persisted
    /// groups, as copies to review here (they were only counted before, so
    /// the sheet listed none of them). Paged through, nothing cut; copies in
    /// the Trash are left out.
    private static func persistedNearGroups() async throws -> [[MBOXParser.RawEmail]] {
        let store = ScopeJobEnvironment.store
        var groups: [[MBOXParser.RawEmail]] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let keys = try await store.nearDuplicateGroupKeysPage(limit: 200, offset: offset)
            if keys.isEmpty { break }
            offset += keys.count
            let rows = try await store.nearDuplicateMembers(groupKeys: keys)
            let grouped = Dictionary(grouping: rows, by: \.groupKey)
            let live = try await withoutTrashed(keys.compactMap { grouped[$0]?.map(\.emailID) }, store: store)
            var byID: [UUID: MBOXParser.RawEmail] = [:]
            let members = live.flatMap { $0 }
            var start = 0
            while start < members.count {
                let chunk = Array(members[start..<min(start + 500, members.count)])
                for email in try await ScopeJobEnvironment.archive.fullEmails(ids: chunk) { byID[email.id] = email }
                start += chunk.count
            }
            groups += live.map { $0.compactMap { byID[$0] } }.filter { $0.count > 1 }
        }
        return groups
    }

    /// IPAD-05 (c): the previous engine's similar groups over its stated
    /// window (the newest `window` emails; CAP-06 names it in Settings ▸
    /// Health ▸ Limits and the note says it on screen).
    nonisolated private static func previousEngineNearGroups(threshold: Double, window: Int) async -> [[MBOXParser.RawEmail]] {
        var emails: [MBOXParser.RawEmail] = []
        let stream = await ArchiveDataService.shared.streamFullEmails(query: .all, batchSize: 200)
        do { for try await b in stream { emails.append(contentsOf: b); if emails.count >= window { break } } } catch { }
        return findNearDuplicates(in: Array(emails.prefix(window)), threshold: threshold)
    }

    /// `previousEngine`: run the pre-3.0 path (switch off, or §3-M3 fallback).
    private func scanForDuplicates(previousEngine: Bool = false) {
        if v3 && !previousEngine {
            isScanning = true
            let includeNear = showNearDuplicates
            let threshold = similarityThreshold
            Task { @MainActor in
                defer { isScanning = false }
                do {
                    let r = try await DuplicatesEngine.exactGroups()
                    (verifiedGroups, candidateGroups) = DuplicateVerification.classify(r.groups)
                    var note = String(localized: "Exact duplicates: whole archive — \(r.receipt.coverageLine)")
                    var near: [[MBOXParser.RawEmail]] = []
                    var coverage = DuplicateSummary.NearCoverage.notChecked
                    if includeNear {
                        // IPAD-05 (c): the similar groups are listed HERE to
                        // review (never bulk-removed). Before, this path only
                        // counted them or named the switch, so a near-duplicate
                        // was never offered and the sheet then claimed the
                        // archive had no duplicate messages at all.
                        if modules?.isOn(.v3NearDuplicates) ?? false {
                            do {
                                let result = try await NearDuplicatesEngine.run(threshold: threshold)
                                near = try await Self.persistedNearGroups()
                                coverage = .wholeArchive
                                note += " " + Inflect.string("Near-duplicates: ^[\(result.groups) group](inflect: true) across the whole archive (\(result.indexed) of \(result.total) emails indexed).")
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                note += " " + String(localized: "Near-duplicates could not be found: \(error.localizedDescription)")
                            }
                        } else {
                            // The previous engine's window, stated on screen
                            // (CAP-06: a named limit in Settings ▸ Health ▸ Limits).
                            let window = AppLimits.previousEngineDuplicateWindow
                            near = await Self.previousEngineNearGroups(threshold: threshold, window: window)
                            coverage = .newest(window)
                            note += " " + String(localized: "Near-duplicates: among the newest \(window.formatted()) emails only (previous engine). The whole archive needs “Whole-archive near-duplicates (3.0)” in Settings ▸ Modules.")
                        }
                    }
                    nearDuplicateGroups = near
                    nearCoverage = coverage
                    v3Note = note
                } catch is CancellationError {
                    v3Note = nil
                } catch {
                    v3Note = EngineGuard.fellBack(.v3Duplicates, error: error)
                    scanForDuplicates(previousEngine: true)
                }
            }
            return
        }
        isScanning = true
        let includeNear = showNearDuplicates
        let threshold = similarityThreshold

        Task.detached(priority: .utility) {
            // v2: scan a bounded working set from the store (the store already
            // enforces message-id dedup at insert; this surfaces near-dupes and
            // content-hash groups over a bounded window).
            var emails: [MBOXParser.RawEmail] = []
            let stream = await ArchiveDataService.shared.streamFullEmails(query: .all, batchSize: 200)
            // CAP-06: the previous engine's window is a named, listed limit
            // (Settings ▸ Health ▸ Limits) and is stated on screen below.
            let window = AppLimits.previousEngineDuplicateWindow
            do { for try await b in stream { emails.append(contentsOf: b); if emails.count >= window { break } } } catch { }
            emails = Array(emails.prefix(window))
            let exactGroups = Self.findExactDuplicates(in: emails)
            let nearGroups: [[MBOXParser.RawEmail]]
            if includeNear {
                nearGroups = Self.findNearDuplicates(in: emails, threshold: threshold)
            } else {
                nearGroups = []
            }

            // The same full comparison as the whole-archive path (DUP-01).
            let classified = DuplicateVerification.classify(exactGroups)
            await MainActor.run {
                self.verifiedGroups = classified.verified
                self.candidateGroups = classified.candidates
                self.nearDuplicateGroups = nearGroups
                self.nearCoverage = includeNear ? .newest(window) : .notChecked
                // Stage A: the window is stated on screen, after a fallback too.
                self.v3Note = Self.previousEngineScopeNote(appendedTo: previousEngine ? self.v3Note : nil)
                self.isScanning = false
            }
        }
    }

    /// What the previous engine's list covers — never left unsaid (plan §1.1).
    /// `existing` is the fallback note when the new engine stopped.
    nonisolated static func previousEngineScopeNote(appendedTo existing: String?) -> String {
        let scope = String(localized: "Groups found among the newest 5,000 emails only (previous engine). The whole archive needs “Whole-archive duplicate groups (3.0)” in Settings ▸ Modules.")
        guard let existing, !existing.isEmpty else { return scope }
        return existing + " " + scope
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

    /// The words two bodies are compared on: lower-cased, split on anything
    /// that is not a letter or digit. Splitting on spaces alone kept the
    /// punctuation on the word, so "…appears twice." and "…appears twice!"
    /// shared only 4 of 6 "words" and a one-character edit never reached the
    /// threshold (IPAD-05 (c), gate 1 walk).
    nonisolated static func similarityWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    nonisolated static func findNearDuplicates(in emails: [MBOXParser.RawEmail], threshold: Double) -> [[MBOXParser.RawEmail]] {
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
                        similarityWords(senderEmails[i].plainBody),
                        similarityWords(senderEmails[j].plainBody)
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
