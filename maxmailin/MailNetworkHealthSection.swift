//
//  MailNetworkHealthSection.swift
//  maxmailin
//
//  V4-01: Settings ▸ Health shows the mail network policy as it is right now —
//  whether this edition has mail connection code, whether Mail is on, each
//  account's permission modes, and how many attempts the policy refused.
//  Read-only; there is no account UI yet (V4-02).
//

import SwiftUI
import Combine
import MailConnectivity

struct MailNetworkHealthSection: View {
    var policy: MailNetworkPolicy = .shared
    @State private var snapshot: MailNetworkPolicy.Snapshot?
    /// Each account's address (the policy knows accounts only by their id).
    @State private var addresses: [UUID: String] = [:]

    var body: some View {
        Section("Mail network") {
            if let s = snapshot {
                LabeledContent(String(localized: "Mail connection code"),
                               value: s.transportsCompiled
                                   ? String(localized: "In this edition")
                                   : String(localized: "Not in this edition"))
                LabeledContent(String(localized: "Mail"),
                               value: s.isMailEnabled ? String(localized: "On") : String(localized: "Off"))
                    .accessibilityIdentifier("health.mailNetwork.state")
                LabeledContent(String(localized: "Cloud AI code"),
                               value: s.cloudAICompiled
                                   ? String(localized: "In this edition")
                                   : String(localized: "Not in this edition"))
                if s.accounts.isEmpty {
                    Text("No mail accounts.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(s.accounts) { account in
                        LabeledContent(Self.label(for: account.id, addresses: addresses)) {
                            Text(Self.modesText(account))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                LabeledContent(String(localized: "Connections allowed"), value: "\(s.permittedAttempts)")
                LabeledContent(String(localized: "Connections refused"), value: "\(s.refusedAttempts)")
                    .accessibilityIdentifier("health.mailNetwork.refused")
                ForEach(MailNetworkRefusal.allCases.filter { (s.refusalsByReason[$0] ?? 0) > 0 }, id: \.self) { reason in
                    Text("\(s.refusalsByReason[reason] ?? 0) × \(reason.explanation)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if s.activeTasks > 0 || s.cancelledTasks > 0 {
                    Text("Mail tasks running: \(s.activeTasks); stopped by a switch: \(s.cancelledTasks)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Every mail connection asks this policy first. It never allows an AI service or remote content.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            snapshot = policy.snapshot()
            addresses = await Self.accountAddresses()
        }
        .onReceive(NotificationCenter.default.publisher(for: MailNetworkPolicy.didChange)
            .receive(on: RunLoop.main)) { _ in
            snapshot = policy.snapshot()
            if snapshot?.accounts.contains(where: { addresses[$0.id] == nil }) == true {
                Task { addresses = await Self.accountAddresses() }
            }
        }
    }

    /// The account's address; never its UUID.
    static func label(for id: UUID, addresses: [UUID: String]) -> String {
        addresses[id] ?? String(localized: "A mail account")
    }

    @MainActor
    static func accountAddresses() async -> [UUID: String] {
        guard let accounts = try? await ConnectedMailRuntime.shared?.registry.accounts() else { return [:] }
        return Dictionary(accounts.map { ($0.id, $0.displayIdentity) }, uniquingKeysWith: { a, _ in a })
    }

    static func modesText(_ account: MailAccountNetworkPolicy) -> String {
        guard account.isEnabled else { return String(localized: "Off") }
        let modes = MailAccountMode.allCases.filter { account.modes.contains($0) }.map(\.displayName)
        return modes.isEmpty ? String(localized: "On, nothing allowed") : modes.joined(separator: ", ")
    }
}
