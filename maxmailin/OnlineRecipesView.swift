@testable import ArchiveCore
import MailConnectivity
//
//  OnlineRecipesView.swift
//  maxmailin
//
//  v4.0 REC-07: the connected-mail recipes — choose → preview → result. The
//  preview's counts come from the provider's listing and the archive (rule 4);
//  the result is read from the capture receipt and the cleanup receipt. A
//  server cleanup has its own confirmation naming its count, and is separate
//  from mailin's Trash.
//

import SwiftUI

/// The connected-mail section of the recipes list (only while Mail runs).
struct OnlineRecipesSection: View {
    @Binding var running: OnlineRecipeKind?

    var body: some View {
        if ConnectedMailRuntime.shared != nil {
            Section {
                ForEach(OnlineRecipeKind.allCases) { kind in
                    Button { running = kind } label: {
                        HStack(alignment: .top, spacing: Spacing.small) {
                            Image(systemName: kind.icon).font(.title3).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title).font(Typography.callout).fontWeight(.semibold)
                                Text(kind.summary).font(Typography.caption1).foregroundColor(AppColors.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recipes.online.\(kind.rawValue)")
                    .accessibilityHint(kind.summary)
                }
            } header: {
                Text("Connected mail")
            }
        }
    }
}

struct OnlineRecipeRunView: View {
    let kind: OnlineRecipeKind
    var onFinished: () -> Void = {}

    enum Stage { case choose, preview, running, captured, cleanupReview, result }
    enum ServerChoice: String, CaseIterable, Identifiable {
        case leave, trash, archive
        var id: String { rawValue }
        var label: String {
            switch self {
            case .leave: return String(localized: "Leave the server unchanged")
            case .trash: return String(localized: "Move to the server's Trash")
            case .archive: return String(localized: "Archive on the server (Gmail)")
            }
        }
    }

    @State private var stage: Stage = .choose
    @State private var accounts: [MailAccount] = []
    @State private var accountID: UUID?
    @State private var folders: [RemoteFolderOccurrence] = []
    @State private var chosenFolders: Set<String> = []
    @State private var fromDay = ""
    @State private var toDay = ""
    @State private var sender = ""
    @State private var includeUndetermined = true
    @State private var preview: OnlineCapturePreview?
    @State private var outcome: OnlineCaptureOutcome?
    @State private var serverChoice: ServerChoice = .leave
    @State private var review: OnlineCleanupReview?
    @State private var confirmCleanup = false
    @State private var result: OnlineRecipeResult?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var runtime: ConnectedMailRuntime? { ConnectedMailRuntime.shared }

    private func engine(_ runtime: ConnectedMailRuntime) -> OnlineRecipeEngine {
        OnlineRecipeEngine(env: .production(runtime: runtime))
    }

    var body: some View {
        Form {
            Section { Text(kind.summary).font(Typography.caption1).foregroundColor(AppColors.secondary) }
            if runtime == nil {
                Section { Text("Mail is switched off.").foregroundColor(.orange) }
            } else {
                switch stage {
                case .choose: chooseStage
                case .preview: previewStage
                case .running: runningStage
                case .captured: capturedStage
                case .cleanupReview: cleanupStage
                case .result: resultStage
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundColor(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind.title)
        .confirmationDialog(review?.confirmTitle ?? "", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button(review?.confirmTitle ?? "", role: .destructive) { runCleanup() }
        } message: {
            Text("Only the messages counted here change on the server, one at a time. The copies saved in mailin are kept and checked again afterwards.")
        }
        .task { await loadAccounts() }
        .onDisappear { task?.cancel() }
    }

    // MARK: Choose

    private func loadAccounts() async {
        guard let runtime else { return }
        let all = (try? await runtime.registry.accounts()) ?? []
        accounts = all.filter { runtime.engines[$0.id] != nil }
        if accountID == nil { accountID = accounts.first?.id }
        await loadFolders()
    }

    private func loadFolders() async {
        guard let runtime, let accountID else { return }
        do { folders = try await runtime.folderList(accountID) } catch { self.error = error.localizedDescription }
    }

    @ViewBuilder
    private var chooseStage: some View {
        Section(String(localized: "Account")) {
            if accounts.isEmpty {
                Text("No account is saving mail. Add an account and allow Preserve mail first.")
                    .foregroundColor(AppColors.secondary)
            }
            Picker(String(localized: "Account"), selection: $accountID) {
                ForEach(accounts) { Text($0.displayIdentity).tag(Optional($0.id)) }
            }
            .onChange(of: accountID) { _, _ in chosenFolders = []; Task { await loadFolders() } }
            .accessibilityIdentifier("online.account")
        }
        Section(String(localized: "Folders and labels")) {
            Text(chosenFolders.isEmpty ? String(localized: "Every folder") : String(localized: "\(chosenFolders.count) chosen"))
                .font(Typography.caption1).foregroundColor(AppColors.secondary)
            ForEach(folders, id: \.serverID) { f in
                Toggle(f.displayPath, isOn: Binding(get: { chosenFolders.contains(f.serverID) },
                                                    set: { if $0 { chosenFolders.insert(f.serverID) } else { chosenFolders.remove(f.serverID) } }))
            }
        }
        Section(String(localized: "Dates and sender")) {
            TextField(String(localized: "From (yyyy-MM-dd)"), text: $fromDay)
            TextField(String(localized: "To (yyyy-MM-dd)"), text: $toDay)
            TextField(String(localized: "Sender"), text: $sender)
            Toggle(String(localized: "Also save messages whose date or sender the server's list does not show"), isOn: $includeUndetermined)
        }
        Section {
            Button(String(localized: "Preview")) { Task { await makePreview() } }
                .keyboardShortcut(.defaultAction)
                .disabled(accountID == nil)
                .accessibilityIdentifier("online.preview")
        }
    }

    static func day(_ text: String, plusDays: Int = 0) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: t) else { return nil }
        return Calendar.current.date(byAdding: .day, value: plusDays, to: d)
    }

    private func makePreview() async {
        guard let runtime, let accountID else { return }
        error = nil
        if (!fromDay.isEmpty && Self.day(fromDay) == nil) || (!toDay.isEmpty && Self.day(toDay) == nil) {
            error = String(localized: "Dates are written as yyyy-MM-dd.")
            return
        }
        let filter = SelectiveCaptureFilter(folderIDs: chosenFolders, receivedFrom: Self.day(fromDay),
                                            receivedBefore: Self.day(toDay, plusDays: 1), sender: sender,
                                            includeUndetermined: includeUndetermined)
        do {
            preview = try await engine(runtime).previewCapture(account: accountID, filter: filter)
            stage = .preview
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Preview → capture

    @ViewBuilder
    private var previewStage: some View {
        if let preview {
            Section(String(localized: "What will be saved")) {
                ForEach(preview.lines, id: \.self) { Text($0) }
                Text("The list is frozen now: mail arriving later is not added to this run.")
                    .font(Typography.caption2).foregroundColor(AppColors.secondary)
            }
            Section {
                HStack {
                    Button(String(localized: "Back")) { stage = .choose }
                    Spacer()
                    Button(String(localized: "Save \(preview.toCapture) messages")) { runCapture() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview.toCapture == 0)
                        .accessibilityIdentifier("online.capture")
                }
            }
        }
    }

    private var runningStage: some View {
        Section {
            HStack {
                ProgressView().controlSize(.small)
                Text("Working…")
                Spacer()
                Button(String(localized: "Cancel")) { task?.cancel() }
            }
        }
    }

    private func runCapture() {
        guard let runtime, let preview else { return }
        stage = .running
        let e = engine(runtime)
        task = Task { @MainActor in
            outcome = await e.capture(preview, recipe: kind)
            if outcome == nil { error = String(localized: "Saving mail is switched off for this account.") }
            result = outcome?.result
            stage = kind == .archiveAndCleanServer && outcome != nil ? .captured : .result
            onFinished()
        }
    }

    // MARK: Server cleanup (archive-and-clean only)

    @ViewBuilder
    private var capturedStage: some View {
        if let result { factsSections(result) }
        Section {
            Picker(String(localized: "On the server"), selection: $serverChoice) {
                ForEach(ServerChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Text("Server cleanup never removes mailin's copies. Duplicate copies inside mailin are a separate choice: the Archive and safely clean up recipe moves them to mailin's Trash.")
                .font(Typography.caption1).foregroundColor(AppColors.secondary)
            HStack {
                Spacer()
                Button(serverChoice == .leave ? String(localized: "Done") : String(localized: "Review server cleanup")) {
                    if serverChoice == .leave { stage = .result } else { Task { await makeReview() } }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("online.cleanup.review")
            }
        }
    }

    private func makeReview() async {
        guard let runtime, let preview, let outcome, let accountID else { return }
        let e = engine(runtime)
        do {
            review = try await e.cleanupReview(account: accountID, candidates: e.candidates(from: outcome, preview: preview),
                                               action: serverChoice == .archive ? .archiveOnServer : .moveToTrash,
                                               captureFailures: OnlineRecipeEngine.captureFailures(outcome))
            stage = .cleanupReview
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private var cleanupStage: some View {
        if let review {
            Section(String(localized: "Server cleanup")) {
                if let refusal = review.refusal {
                    Label(refusal, systemImage: "hand.raised").foregroundColor(.orange)
                    Text("Nothing will be sent to the server.").font(Typography.caption1)
                } else if let plan = review.plan {
                    Text(String(localized: "\(plan.preview.toChange) of \(plan.preview.selected) messages will change on \(review.accountDisplay); \(plan.preview.excluded) will not. The copies saved in mailin are kept."))
                    ForEach(review.exclusionLines, id: \.self) { Text($0).font(Typography.caption1).foregroundColor(AppColors.secondary) }
                }
            }
            Section {
                HStack {
                    Button(String(localized: "Back")) { stage = .captured }
                    Spacer()
                    Button(review.confirmTitle) { confirmCleanup = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(review.refusal != nil || (review.plan?.included.isEmpty ?? true))
                        .accessibilityIdentifier("online.cleanup.run")
                }
            }
        }
    }

    private func runCleanup() {
        guard let runtime, let review, let plan = review.plan else { return }
        stage = .running
        let e = engine(runtime)
        let earlier = result?.facts ?? []
        task = Task { @MainActor in
            result = await e.executeCleanup(review, confirmation: plan.confirmation(), recipe: kind, earlier: earlier)
            stage = .result
            onFinished()
        }
    }

    // MARK: Result

    @ViewBuilder
    private func factsSections(_ result: OnlineRecipeResult) -> some View {
        Section {
            Label(result.state.label, systemImage: result.isCompleted ? "checkmark.seal.fill" : "exclamationmark.circle")
                .foregroundColor(result.isCompleted ? .green : .orange)
                .accessibilityIdentifier("online.result.state")
            ForEach(result.notes, id: \.self) { Text($0).font(Typography.caption1) }
        }
        ForEach(Array(result.facts.enumerated()), id: \.offset) { _, facts in
            Section { RecipeResultFactsView(facts: facts) }
        }
    }

    @ViewBuilder
    private var resultStage: some View {
        if let result { factsSections(result) }
        Section {
            Button(String(localized: "Run again")) {
                stage = .choose; result = nil; preview = nil; outcome = nil; review = nil; serverChoice = .leave
            }
        }
    }
}
