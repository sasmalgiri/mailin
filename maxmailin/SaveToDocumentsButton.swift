//
//  SaveToDocumentsButton.swift
//  maxmailin
//
//  A universal "Save to Documents" control. Drop it into any tool's header
//  so the user can, at any moment, mint a numbered document that records the
//  job they just did — as STRUCTURED key/value fields, so it opens as a
//  spreadsheet-like table, exports to CSV, and feeds custom reports. Manual by
//  design: the user decides when a result is worth keeping, so merely opening
//  a view never spams the register.
//

import SwiftUI

struct SaveToDocumentsButton: View {
    let type: DocumentType
    let title: String
    /// Builds the structured document at the moment of tapping (captures the
    /// current on-screen result).
    private let make: () -> CapturedDocument

    @State private var savedNumber: String?
    @State private var saving = false

    /// Simple form: one section (named `title`) of key/value fields.
    init(type: DocumentType = .report, title: String,
         fields: @escaping () -> [CapturedDocument.Field]) {
        self.type = type
        self.title = title
        self.make = {
            CapturedDocument(title: title,
                             sections: [CapturedDocument.Section(name: title, fields: fields())])
        }
    }

    /// Full form: build the whole multi-section document.
    init(type: DocumentType = .report, title: String,
         document: @escaping () -> CapturedDocument) {
        self.type = type
        self.title = title
        self.make = document
    }

    var body: some View {
        Button {
            guard !saving, savedNumber == nil else { return }
            saving = true
            let doc = make()
            Task {
                let number = await DocumentRegistry.captureStructured(type, summary: title, document: doc)
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
