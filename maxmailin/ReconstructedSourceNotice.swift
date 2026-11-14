@testable import ArchiveCore
//
//  ReconstructedSourceNotice.swift
//  maxmailin
//
//  Directive §2 "Recover existing imports" (5): a message whose raw source
//  mailin rendered itself (PST/MSG/NSF import) or reconstructed from the
//  original file afterwards says so in the detail view — "reconstructed from
//  <file> on <date>" — and is never presented as captured wire bytes. Reads
//  the two provenance headers (`X-Mailin-Rendered`, `X-Mailin-Reconstructed`)
//  that the raw source itself carries, so the same label travels with every
//  .eml / mbox export.
//

import SwiftUI

struct ReconstructedSourceNotice: View {
    let rawSource: String

    var body: some View {
        let label = RawSourceProvenance.label(for: rawSource)
        if label.isReconstructed || label.rendered != nil {
            HStack(alignment: .top, spacing: Spacing.xSmall) {
                Image(systemName: "doc.badge.gearshape")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(Self.text(label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("detail.reconstructedSource")
        }
    }

    /// "Source reconstructed from two.pst on 7 Nov 2026 — rendered by mailin from the Outlook record, not captured wire bytes."
    static func text(_ label: RawSourceProvenance.Label) -> String {
        var line: String
        if let file = label.sourceFilename {
            let when = label.date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            line = String(localized: "Source reconstructed from \(file) on \(when)")
            if label.fromUnverifiedFile { line += " " + String(localized: "(the file's hash differed from the registered import)") }
        } else {
            line = String(localized: "Source rendered by mailin")
        }
        if let format = label.rendered, !format.isEmpty {
            line += " — " + String(localized: "built from the \(format) record, not captured wire bytes.")
        } else {
            line += " — " + String(localized: "not captured wire bytes.")
        }
        return line
    }
}
