//
//  SaveToDocumentsButton.swift
//  maxmailin
//
//  A universal "Save to Documents" control. Drop it into any tool's header
//  so the user can, at any moment, mint a numbered document that records the
//  job they just did — the SAP promise made available on every page, not
//  just the guided workflows. Manual by design: the user decides when a
//  result is worth keeping, so merely opening a view never spams the register.
//

import SwiftUI

struct SaveToDocumentsButton: View {
    /// The document type to post (RPT for analyses, EXP for exports, etc.).
    let type: DocumentType
    /// A short human title for the document summary.
    let title: String
    /// Produces the full saved work at the moment of tapping — evaluated
    /// lazily so it captures the current on-screen result.
    let snapshot: () -> String

    @State private var savedNumber: String?
    @State private var saving = false

    init(type: DocumentType = .report, title: String, snapshot: @escaping () -> String) {
        self.type = type
        self.title = title
        self.snapshot = snapshot
    }

    var body: some View {
        Button {
            guard !saving, savedNumber == nil else { return }
            saving = true
            let work = snapshot()
            Task {
                let number = await DocumentRegistry.capture(type, summary: title, body: work)
                await MainActor.run {
                    savedNumber = number
                    saving = false
                }
            }
        } label: {
            if let n = savedNumber {
                Label("Saved \(n)", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if saving {
                Label("Saving…", systemImage: "square.and.arrow.down.on.square")
            } else {
                Label("Save to Documents", systemImage: "square.and.arrow.down.on.square")
            }
        }
        .controlSize(.small)
        .disabled(saving || savedNumber != nil)
        .help("Record this result as a numbered document you can reopen later from Work Center ▸ Documents.")
        .accessibilityLabel(savedNumber.map { "Saved as \($0)" } ?? "Save to Documents")
    }
}
