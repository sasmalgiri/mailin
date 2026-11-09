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

struct MailNetworkHealthSection: View {
    var policy: MailNetworkPolicy = .shared
    @State private var snapshot: MailNetworkPolicy.Snapshot?

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
                        LabeledContent(account.id.uuidString.prefix(8).description) {
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
        .task { snapshot = policy.snapshot() }
        .onReceive(NotificationCenter.default.publisher(for: MailNetworkPolicy.didChange)
            .receive(on: RunLoop.main)) { _ in
            snapshot = policy.snapshot()
        }
    }

    static func modesText(_ account: MailAccountNetworkPolicy) -> String {
        guard account.isEnabled else { return String(localized: "Off") }
        let modes = MailAccountMode.allCases.filter { account.modes.contains($0) }.map(\.displayName)
        return modes.isEmpty ? String(localized: "On, nothing allowed") : modes.joined(separator: ", ")
    }
}
