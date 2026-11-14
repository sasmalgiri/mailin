@testable import ArchiveCore
import MailConnectivity
//
//  MailOutboxViews.swift
//  maxmailin
//
//  Plan v4 V4-13 (§6 outbox, server actions and safe cleanup):
//   • the outbox — every item's state in plain words ("accepted, not yet
//     confirmed delivered" — never "delivered"), the undo-send countdown,
//     "Check Sent" for an uncertain or accepted item, "Send anyway" only after
//     an uncertain outcome was checked, held items waiting for a decision;
//   • the safe server cleanup — preview with counts and reasons, then a
//     confirmation that names the count (typed), then the receipt "X of Y".
//

import SwiftUI

// MARK: - Outbox

struct MailOutboxList: View {
    let model: MailWorkspaceModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                if model.outbox.isEmpty {
                    Text("The outbox is empty.").foregroundStyle(.secondary)
                }
                ForEach(model.outbox) { op in
                    MailOutboxRow(model: model, op: op, hold: model.holds[op.id], now: context.date)
                }
            }
        }
        .navigationTitle(String(localized: "Outbox"))
        .refreshable { await model.reloadOutbox() }
        .task {
            // Follow the driver: states change as items are submitted.
            while !Task.isCancelled {
                await model.reloadOutbox()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

private struct MailOutboxRow: View {
    let model: MailWorkspaceModel
    let op: OutboxOperation
    let hold: OutboxHoldReason?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let account = model.account(op.accountID)?.account {
                    MailAccountBadge(account: account)
                }
                Spacer()
                Text(op.createdAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
            Text(op.envelopeRecipients.joined(separator: ", ")).font(.callout).lineLimit(1)
            Text(MailOutboxText.state(op.state))
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("mail.outbox.state")
            if let hold { Text(MailOutboxText.hold(hold)).font(.caption).foregroundStyle(.orange) }
            if case .accepted = op.state {
                Text("Accepted means the provider took the message for delivery. It does not prove it reached the recipients.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            buttons
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: Spacing.xSmall) {
            if let seconds = MailOutboxText.undoSecondsLeft(op, now: now) {
                Button(String(localized: "Undo Send (\(seconds))")) {
                    Task { await model.outboxAction { try await model.backend.cancelSend(op.id) } }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Text("Undo Send, \(seconds) seconds left"))
            } else if MailOutboxText.canCancel(op.state) {
                Button(String(localized: "Cancel sending")) {
                    Task { await model.outboxAction { try await model.backend.cancelSend(op.id) } }
                }
            }
            if MailOutboxText.canRetryNow(op.state) {
                Button(String(localized: "Try again now")) {
                    Task { await model.outboxAction { try await model.backend.retryNow(op.id) } }
                }
            }
            if MailOutboxText.canCheckSent(op.state) {
                Button(String(localized: "Check Sent")) {
                    Task { await model.outboxAction { try await model.backend.checkSent(op.id) } }
                }
                .help(String(localized: "Looks for this message in the account's Sent folder"))
            }
            // Only after an uncertain outcome was checked.
            if MailOutboxText.canResendAnyway(op.state) {
                Button(String(localized: "Send anyway"), role: .destructive) {
                    Task { await model.outboxAction { try await model.backend.resendAnyway(op.id) } }
                }
                .help(String(localized: "Sends the same message again. If the first attempt did arrive, recipients get it twice."))
            }
            if hold?.needsUserDecision == true {
                Button(String(localized: "Send now")) {
                    Task { await model.outboxAction { try await model.backend.sendHeldNow(op.id) } }
                }
                Button(String(localized: "Keep as draft")) {
                    Task { await model.outboxAction { try await model.backend.keepHeldAsDraft(op.id) } }
                }
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Safe cleanup

struct MailCleanupView: View {
    let model: MailWorkspaceModel
    let accountID: UUID
    /// One message (from its own view); nil = the account's messages listed now.
    var only: UUID? = nil
    let dismiss: () -> Void
    @State private var action: CleanupAction = .moveToTrash
    @State private var plan: CleanupPlan?
    @State private var typed = ""
    @State private var receipt: CleanupReceipt?
    @State private var working = false
    @State private var error: String?

    private var account: MailAccount? { model.account(accountID)?.account }
    private var selection: [ConnectedMailboxRow] {
        model.rows.filter { $0.accountID == accountID && $0.onServer && (only == nil || $0.emailID == only) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let receipt {
                    Section {
                        Text(MailCleanupGate.receipt(receipt))
                            .accessibilityIdentifier("mail.cleanup.receipt")
                    } header: {
                        Text("Receipt")
                    }
                } else if let plan {
                    previewSection(plan)
                    confirmSection(plan)
                } else {
                    chooseSection
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Safe server cleanup"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(receipt == nil ? String(localized: "Cancel") : String(localized: "Done"), action: dismiss)
                }
            }
        }
    }

    private var chooseSection: some View {
        Section {
            Text("\(selection.count) messages of \(account?.displayIdentity ?? "") are listed now and still on the server.")
            Picker(String(localized: "Change"), selection: $action) {
                Text(MailCleanupGate.actionTitle(.moveToTrash)).tag(CleanupAction.moveToTrash)
                if account?.provider == .gmail {
                    Text(MailCleanupGate.actionTitle(.archiveOnServer)).tag(CleanupAction.archiveOnServer)
                }
            }
            Button(String(localized: "Preview")) {
                Task {
                    working = true
                    defer { working = false }
                    do { plan = try await model.backend.planCleanup(selection, action: action, account: accountID) } catch {
                        self.error = ConnectedMailErrorText.text(for: error)
                    }
                }
            }
            .disabled(selection.isEmpty || working)
        } footer: {
            Text("Only messages whose saved copy in mailin is checked byte for byte, and that are not on hold, can be changed. Nothing changes until you confirm the count. An independent export or backup is not checked by this step.")
        }
    }

    private func previewSection(_ plan: CleanupPlan) -> some View {
        Section {
            LabeledContent(String(localized: "Selected"), value: "\(plan.preview.selected)")
            LabeledContent(String(localized: "Will be changed on the server"), value: "\(plan.preview.toChange)")
            LabeledContent(String(localized: "Left alone"), value: "\(plan.preview.excluded)")
            ForEach(plan.preview.excludedByReason.sorted { $0.key < $1.key }, id: \.key) { reason, count in
                Text("\(count) × \(MailCleanupGate.exclusionTitle(reason))").font(.caption).foregroundStyle(.secondary)
            }
            Text("The copies saved in mailin are not changed.").font(.caption)
        } header: {
            Text("Preview: \(MailCleanupGate.actionTitle(plan.action))")
        }
    }

    private func confirmSection(_ plan: CleanupPlan) -> some View {
        Section {
            Text(MailCleanupGate.confirmationPrompt(plan))
            TextField(String(localized: "Number of messages"), text: $typed)
                .accessibilityIdentifier("mail.cleanup.count")
            Button(String(localized: "Change \(plan.included.count) messages on the server"), role: .destructive) {
                Task {
                    working = true
                    defer { working = false }
                    do {
                        receipt = try await model.backend.runCleanup(plan, confirmation: plan.confirmation())
                        await model.reloadMailbox()
                    } catch { self.error = ConnectedMailErrorText.text(for: error) }
                }
            }
            .disabled(!MailCleanupGate.confirms(typed: typed, plan: plan) || working)
            .accessibilityIdentifier("mail.cleanup.run")
        }
    }
}
