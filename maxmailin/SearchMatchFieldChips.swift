@testable import ArchiveCore
//
//  SearchMatchFieldChips.swift
//  maxmailin
//

import SwiftUI

// MARK: - Row indicator

/// The compact "matched in" strip a result row shows under its subject while
/// a search is active. Renders nothing for an empty list, so it costs no
/// height when no search is running.
struct SearchMatchFieldChips: View {
    let fields: [SearchMatchField]
    /// `.increased` on the iPad's open-email row (white on deep blue).
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if !fields.isEmpty {
            HStack(spacing: 4) {
                ForEach(fields, id: \.self) { field in
                    Label(field.label, systemImage: field.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        // On the blue open-email row: white on a lighter capsule
                        // (navy on blue measured 2.3:1). Elsewhere 75 % primary,
                        // not system secondary grey (3.9:1 on its capsule).
                        .foregroundStyle(prominence == .increased ? Color.white : Color.primary.opacity(0.75))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(prominence == .increased ? Color.white.opacity(0.22) : Color.secondary.opacity(0.12),
                                    in: Capsule())
                }
            }
            .help("Where this search matched")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Matched in " + fields.map(\.label).joined(separator: ", "))
            .accessibilityIdentifier("search.matchedFields")
        }
    }
}
