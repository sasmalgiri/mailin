//
//  CollectToPreserve.swift
//  maxmailin
//
//  §3-E7 (switch: `v3LegalState`). A matter can preserve everything it
//  collects: with this on, every batch an import commits is placed on legal
//  hold and sealed (set-once seals) as it lands — no window between import
//  and hold in which an email could be altered or deleted unprotected.
//  Off by default; the choice is per device and shown where it is set.
//

import SwiftUI

enum CollectToPreserve {
    static let key = "matter.collectToPreserve"
    nonisolated(unsafe) static var engineOn = false

    /// Effective only with the legal-data engine on.
    static var isOn: Bool { engineOn && UserDefaults.standard.bool(forKey: key) }
}

/// The setting, shown in Custodians and E-Discovery when the engine is on.
struct CollectToPreserveToggle: View {
    @AppStorage(CollectToPreserve.key) private var on = false

    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold and seal everything as it is imported")
                Text("Each imported email is placed on legal hold and sealed the moment it is stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: on) { _, value in
            ForensicManager.shared.logAction("Collect-to-preserve \(value ? "on" : "off")",
                                             detail: "Imports \(value ? "are" : "are no longer") held and sealed as they are stored")
        }
    }
}
