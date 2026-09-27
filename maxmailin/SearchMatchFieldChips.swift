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

    var body: some View {
        if !fields.isEmpty {
            HStack(spacing: 4) {
                ForEach(fields, id: \.self) { field in
                    Label(field.label, systemImage: field.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .help("Where this search matched")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Matched in " + fields.map(\.label).joined(separator: ", "))
            .accessibilityIdentifier("search.matchedFields")
        }
    }
}
