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
            Button("Remove Selected") {
                let (allowed, blocked) = CustodianManager.shared.filterProtected(selectedForRemoval)
                if !allowed.isEmpty {
                    model.removeDuplicateEmails(ids: allowed)
                }
                if !blocked.isEmpty {
                    legalHoldWarning = "\(blocked.count) email(s) skipped — under legal hold with evidence seal."
                    return
                }
                closeSheet()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.error)
            .disabled(selectedForRemoval.isEmpty)
            .accessibilityLabel("Remove \(selectedForRemoval.count) selected emails")
            .accessibilityHint("Permanently removes selected duplicate emails")
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private func scanForDuplicates() {
        isScanning = true
        let emails = model.allEmails
        let includeNear = showNearDuplicates
        let threshold = similarityThreshold

        Task.detached(priority: .utility) {
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
