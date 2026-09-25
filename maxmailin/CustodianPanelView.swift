import SwiftUI
#if os(macOS)
import AppKit
#endif

struct CustodianPanelView: View {
    // v2: bounded most-recent working set from the store (no injected corpus).
    @State private var workingSet: [MBOXParser.RawEmail] = []
    @State private var archiveTotal = 0
    @ObservedObject var manager: CustodianManager
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss
    @State private var newCustodianName = ""
    @State private var selectedCustodian: String?
    @State private var showAssignSheet = false
    @State private var showDetailOnIOS = false
    @State private var showTutorial = false
    /// Seal verdicts from the last "Verify Seals" run, per email.
    ///
    /// Placing a legal hold computes a SHA-256 seal over the message and
    /// persists it (`evidence_seals.json`), and `verifyEvidenceSeal` recomputes
    /// it and logs "Evidence Seal BROKEN" on a mismatch — but nothing ever
    /// called it. Seals were written and never checked, so the one audit-log
    /// entry that records tampering under legal hold could not be produced and
    /// the user had no way to ask whether held evidence was still intact.
    @State private var sealVerdicts: [UUID: CustodianManager.SealVerification] = [:]
    @State private var sealSummary: String?
    @State private var sealSummaryIsBad = false
    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            #if os(macOS)
            HSplitView {
                custodianList
                    .frame(minWidth: 200)
                detailPanel
                    .frame(minWidth: 300)
            }
            #else
            if selectedCustodian == nil && !showDetailOnIOS {
                custodianList
            } else {
                detailPanel
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                showDetailOnIOS = false
                                selectedCustodian = nil
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                            }
                        }
                    }
            }
            #endif
        }
        .featureTutorial(.custodianPanel, key: "custodian_panel_tutorial_seen", isPresented: $showTutorial)
        .task {
            archiveTotal = (try? await ArchiveDataService.shared.count()) ?? 0
            guard workingSet.isEmpty else { return }
            var acc: [MBOXParser.RawEmail] = []
            let stream = ArchiveDataService.shared.streamFullEmails(query: .all, batchSize: 200)
            do { for try await b in stream { acc.append(contentsOf: b); if acc.count >= 2000 { break } } } catch { }
            workingSet = Array(acc.prefix(2000))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label("Custodian Manager", systemImage: "person.badge.shield.checkmark")
                    .font(Typography.title2)
                Text("Assign custodians to emails and manage legal holds.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            Button {
                exportCustodianReport()
            } label: {
                Label("Export Report", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(CompactSecondaryButtonStyle())
            .accessibilityLabel("Export custodian report")
            TutorialHelpButton(showTutorial: $showTutorial)
            SaveToDocumentsButton(title: "Custodian Panel") {
                [.init(key: "Working set", value: "\(workingSet.count)")]
            }
            if isPresented != nil {
                Button { closeSheet() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close custodian manager")
            }
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private var custodianList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Custodians")
                .font(Typography.headline)
                .padding(.horizontal, Spacing.small)

            HStack {
                TextField("New custodian name", text: $newCustodianName)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    guard !newCustodianName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    showAssignSheet = true
                }
                .buttonStyle(CompactPrimaryButtonStyle())
                .disabled(newCustodianName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add custodian")
                .accessibilityHint("Adds the new custodian and assigns to visible emails")
            }
            .padding(.horizontal, Spacing.small)

            List(selection: $selectedCustodian) {
                Button {
                    selectedCustodian = nil
                    showDetailOnIOS = true
                } label: {
                    HStack {
                        Image(systemName: "tray.full")
                            .accessibilityHidden(true)
                        Text("All Emails")
                        Spacer()
                        Text("\(archiveTotal)")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All Emails, \(archiveTotal)")

                let unassigned = workingSet.filter { manager.custodian(for: $0.id) == nil }
                Button {
                    selectedCustodian = "__unassigned__"
                    showDetailOnIOS = true
                } label: {
                    HStack {
                        Image(systemName: "questionmark.circle")
                            .accessibilityHidden(true)
                        Text("Unassigned")
                        Spacer()
                        Text("\(unassigned.count)")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unassigned, \(unassigned.count) emails")

                ForEach(manager.allCustodians, id: \.self) { custodian in
                    Button {
                        selectedCustodian = custodian
                        showDetailOnIOS = true
                    } label: {
                        HStack {
                            Image(systemName: "person.fill")
                                .accessibilityHidden(true)
                            Text(custodian)
                            Spacer()
                            let count = manager.emailIDs(for: custodian).count
                            Text("\(count)")
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(custodian), \(manager.emailIDs(for: custodian).count) emails")
                }
            }

            HStack(spacing: Spacing.small) {
                let legalHoldCount = manager.legalHolds.count
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Text("\(legalHoldCount) under legal hold")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.horizontal, Spacing.small)
            .padding(.bottom, Spacing.small)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(manager.legalHolds.count) emails under legal hold")
        }
    }

    // MARK: - Evidence seal verification

    @ViewBuilder
    private func sealBadge(_ verdict: CustodianManager.SealVerification) -> some View {
        switch verdict {
        case .intact:
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(AppColors.success)
                .help("Seal intact — the message matches the hash taken when the hold was placed")
                .accessibilityLabel("Evidence seal intact")
        case .tampered:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppColors.error)
                .help("SEAL BROKEN — this message no longer matches its seal. Recorded in the audit trail.")
                .accessibilityLabel("Evidence seal broken")
        case .noSeal:
            Image(systemName: "questionmark.circle")
                .foregroundColor(AppColors.warning)
                .help("Under legal hold but no seal was recorded — nothing to compare against")
                .accessibilityLabel("No evidence seal recorded")
        case .notHeld:
            EmptyView()
        }
    }

    /// Recompute every held message's hash and compare it to its seal. A
    /// mismatch is logged to the audit trail by `verifyEvidenceSeal` itself,
    /// so the record exists whether or not anyone reads this screen again.
    private func verifySeals(_ emails: [MBOXParser.RawEmail]) {
        var verdicts: [UUID: CustodianManager.SealVerification] = [:]
        var intact = 0, broken = 0, unsealed = 0
        for email in emails {
            let verdict = manager.verifyEvidenceSeal(email)
            verdicts[email.id] = verdict
            switch verdict {
            case .intact: intact += 1
            case .tampered: broken += 1
            case .noSeal: unsealed += 1
            case .notHeld: verdicts.removeValue(forKey: email.id)
            }
        }
        sealVerdicts = verdicts
        sealSummaryIsBad = broken > 0 || unsealed > 0

        var parts = ["\(intact) intact"]
        if broken > 0 { parts.append("\(broken) BROKEN") }
        if unsealed > 0 { parts.append("\(unsealed) with no seal recorded") }
        sealSummary = "Verified \(verdicts.count) sealed message\(verdicts.count == 1 ? "" : "s"): "
            + parts.joined(separator: ", ")
            + (broken > 0 ? ". Every break is recorded in the audit trail." : "")

        ForensicManager.shared.logAction(
            "Evidence Seals Verified",
            detail: "\(verdicts.count) checked — \(intact) intact, \(broken) broken, \(unsealed) unsealed")
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            let scopedEmails: [MBOXParser.RawEmail] = {
                guard let sel = selectedCustodian else { return workingSet }
                if sel == "__unassigned__" {
                    return workingSet.filter { manager.custodian(for: $0.id) == nil }
                }
                let ids = Set(manager.emailIDs(for: sel))
                return workingSet.filter { ids.contains($0.id) }
            }()

            HStack {
                Text("\(scopedEmails.count) emails")
                    .font(Typography.headline)
                Spacer()
                if let sel = selectedCustodian, sel != "__unassigned__" {
                    Button("Place All on Legal Hold") {
                        manager.placeLegalHold(on: scopedEmails)
                    }
                    .buttonStyle(CompactSecondaryButtonStyle())
                }
                let heldInScope = scopedEmails.filter { manager.isUnderLegalHold($0.id) }
                if !heldInScope.isEmpty {
                    Button("Verify Seals (\(heldInScope.count))") {
                        verifySeals(heldInScope)
                    }
                    .buttonStyle(CompactSecondaryButtonStyle())
                    .help("Recompute each held message's hash and compare it to the seal taken when the hold was placed")
                }
            }
            .padding(.horizontal, Spacing.small)
            .padding(.top, Spacing.small)

            if let sealSummary {
                Label(sealSummary, systemImage: sealSummaryIsBad
                      ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(Typography.caption1)
                    .foregroundColor(sealSummaryIsBad ? AppColors.error : AppColors.success)
                    .padding(.horizontal, Spacing.small)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                ForEach(scopedEmails, id: \.id) { email in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(email.headers["Subject"] ?? "(No Subject)")
                                .font(Typography.callout)
                                .lineLimit(1)
                            Text(email.headers["From"] ?? "")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if manager.isUnderLegalHold(email.id) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(.orange)
                                .help("Under legal hold")
                                .accessibilityLabel("Under legal hold")
                        }
                        if let verdict = sealVerdicts[email.id] {
                            sealBadge(verdict)
                        }
                        if let c = manager.custodian(for: email.id) {
                            Text(c)
                                .font(Typography.caption2)
                                .padding(.horizontal, Spacing.xxSmall)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(CornerRadius.small)
                                .accessibilityLabel("Assigned to \(c)")
                        }
                        Menu {
                            ForEach(manager.allCustodians, id: \.self) { c in
                                Button(c) {
                                    manager.assignCustodian(c, to: email.id)
                                }
                            }
                            Divider()
                            Button("Remove Custodian") {
                                manager.removeCustodian(from: email.id)
                            }
                            Divider()
                            if manager.isUnderLegalHold(email.id) {
                                Button("Remove Legal Hold") {
                                    manager.removeLegalHold(email.id)
                                }
                            } else {
                                Button("Place Legal Hold") {
                                    manager.placeLegalHold(email.id, email: email)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(AppColors.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Actions for \(email.headers["Subject"] ?? "email")")
                    }
                }
            }
        }
        .alert("Assign Custodian", isPresented: $showAssignSheet) {
            Button("Assign to All Visible") {
                let scopedEmails: [MBOXParser.RawEmail] = {
                    guard let sel = selectedCustodian else { return workingSet }
                    if sel == "__unassigned__" {
                        return workingSet.filter { manager.custodian(for: $0.id) == nil }
                    }
                    let ids = Set(manager.emailIDs(for: sel))
                    return workingSet.filter { ids.contains($0.id) }
                }()
                manager.assignCustodian(newCustodianName.trimmingCharacters(in: .whitespaces), to: scopedEmails.map(\.id))
                newCustodianName = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Assign '\(newCustodianName)' to all currently visible emails?")
        }
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
    }

    private func exportCustodianReport() {
        let report = manager.custodianReport(emails: workingSet)
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "custodian_report.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custodian_report.txt")
        #endif
        try? report.write(to: url, atomically: true, encoding: .utf8)
        #if os(iOS)
        shareItems = [url]
        showShareSheet = true
        #endif
    }
}
