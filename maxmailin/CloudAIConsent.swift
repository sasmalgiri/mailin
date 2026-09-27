@testable import ArchiveCore
//
//  CloudAIConsent.swift
//  maxmailin
//
//  I5: nothing leaves the device for a cloud model without an explicit,
//  per-request yes. `CloudAIConsentCenter.authorize` is awaited by the cloud
//  provider before every request; it shows the sheet (provider, model, how
//  many bytes of what, the org policy state) and resolves the caller's
//  continuation with the answer. With no sheet host installed the answer is
//  NO — the gate fails closed. "Allow for this session" is the only shortcut,
//  and it dies with the process.
//
//  The org hard-off (`ManagedConfig.disableCloudAI`) is checked here as well
//  as in the provider, so a managed install refuses before it even asks.
//

import SwiftUI

struct CloudAIConsentRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var provider: String
    var model: String
    var purpose: String
    var bytesToSend: Int
    var excerpt: String   // first ~300 characters of what would be sent

    var bytesLabel: String { ByteCountFormatter.string(fromByteCount: Int64(bytesToSend), countStyle: .file) }
}

enum CloudAIConsentDecision: Equatable, Sendable {
    case allowOnce
    case allowForSession
    case deny
}

@MainActor
@Observable
final class CloudAIConsentCenter {
    static let shared = CloudAIConsentCenter()

    /// The request waiting for the user, if any. The root shell presents it.
    private(set) var pending: CloudAIConsentRequest?
    private var continuation: CheckedContinuation<CloudAIConsentDecision, Never>?
    /// "Allow for this session" — cleared on relaunch by construction.
    private(set) var sessionAllowed = false
    /// True once a host attached the sheet; without one the gate fails closed.
    var hasHost = false
    /// Every decision this session, newest first, for the provenance record.
    private(set) var log: [(request: CloudAIConsentRequest, decision: CloudAIConsentDecision, at: Date)] = []

    private init() {}

    /// Awaited by the provider. Returns true only for an explicit allow.
    func authorize(_ request: CloudAIConsentRequest) async -> Bool {
        if ManagedConfig.disableCloudAI { record(request, .deny); return false }
        if sessionAllowed { record(request, .allowForSession); return true }
        guard hasHost, pending == nil else { record(request, .deny); return false }
        pending = request
        let decision = await withCheckedContinuation { (c: CheckedContinuation<CloudAIConsentDecision, Never>) in
            continuation = c
        }
        pending = nil
        continuation = nil
        if decision == .allowForSession { sessionAllowed = true }
        record(request, decision)
        return decision != .deny
    }

    func resolve(_ decision: CloudAIConsentDecision) {
        continuation?.resume(returning: decision)
    }

    func revokeSessionAllowance() { sessionAllowed = false }

    private func record(_ request: CloudAIConsentRequest, _ decision: CloudAIConsentDecision) {
        log.insert((request, decision, Date()), at: 0)
        if log.count > 200 { log.removeLast() }
    }
}

/// The sheet. Attached once at the root shell; renders nothing until a
/// request is pending.
struct CloudAIConsentSheetModifier: ViewModifier {
    @State private var center = CloudAIConsentCenter.shared

    func body(content: Content) -> some View {
        content
            .onAppear { center.hasHost = true }
            .sheet(item: Binding(get: { center.pending }, set: { _ in })) { request in
                CloudAIConsentSheet(request: request) { decision in center.resolve(decision) }
                    .interactiveDismissDisabled()
            }
    }
}

struct CloudAIConsentSheet: View {
    let request: CloudAIConsentRequest
    let onDecision: (CloudAIConsentDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to \(request.provider)?").font(.headline)
                    Text("\(request.purpose) — model \(request.model)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("About \(request.bytesLabel) of text from your archive would leave this Mac and be processed by \(request.provider) under its terms. Nothing is sent unless you allow it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("What would be sent (beginning)") {
                ScrollView {
                    Text(request.excerpt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            if ManagedConfig.disableCloudAI {
                Label("Your organisation has switched cloud AI off. This request will be refused.", systemImage: "building.2")
                    .font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Don't Send", role: .cancel) { onDecision(.deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow for This Session") { onDecision(.allowForSession) }
                    .disabled(ManagedConfig.disableCloudAI)
                    .help("Skips this question until mailin is quit. Nothing is remembered across launches.")
                Button("Send Once") { onDecision(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .disabled(ManagedConfig.disableCloudAI)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .accessibilityIdentifier("cloudAI.consent")
    }
}
