//
//  SaveToDocumentsButton.swift
//  maxmailin
//
//  A universal capture control. Drop it into any tool's header so the tool's
//  result is recorded as a numbered, STRUCTURED document (key/value fields →
//  table/CSV/reports). Two modes, governed by the app-wide "Auto-save my work"
//  setting (Settings ▸ default ON):
//    • Auto  — records once, hands-free, after a short dwell (so a quick glance
//              or a mis-tap never posts a document). Minimal-touch: no click.
//    • Manual — shows a "Save to Documents" button the user taps when ready.
//

import SwiftUI

/// App-wide preference: when on, viewer tools record their result hands-free.
enum DocumentCapturePrefs {
    static let autoKey = "autoCaptureViewerDocuments"
}

struct SaveToDocumentsButton: View {
    let type: DocumentType
    let title: String
    private let make: () -> CapturedDocument

    @AppStorage(DocumentCapturePrefs.autoKey) private var autoCapture = true
    @State private var savedNumber: String?
    @State private var saving = false
    @State private var didAutoAttempt = false

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
        Group {
            if autoCapture {
                // Hands-free: a status chip, no button to press.
                Label(savedNumber.map { "Auto-saved \($0)" } ?? "Auto-save on",
                      systemImage: savedNumber != nil ? "checkmark.circle.fill" : "square.and.arrow.down.on.square")
                    .font(Typography.caption2)
                    .foregroundColor(savedNumber != nil ? .green : AppColors.secondary)
                    .help("This result is recorded to Documents automatically. Turn off in Settings ▸ Auto-save my work.")
            } else {
                Button { Task { await performSave() } } label: {
                    if let n = savedNumber {
                        Label("Saved \(n)", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                    } else if saving {
                        Label("Saving…", systemImage: "square.and.arrow.down.on.square")
                    } else {
                        Label("Save to Documents", systemImage: "square.and.arrow.down.on.square")
                    }
                }
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(saving || savedNumber != nil)
                .help("Record this result as a numbered document you can reopen from Work Center ▸ Documents. (⌘S)")
            }
        }
        .task {
            // Auto mode: record once, but only after the view has stayed open
            // ~1.5s (a real visit, not a glance). The .task is cancelled if the
            // user leaves first, so nothing is posted for a quick pass-through.
            guard autoCapture, !didAutoAttempt, savedNumber == nil else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, savedNumber == nil else { return }
            didAutoAttempt = true
            await performSave()
        }
    }

    @MainActor
    private func performSave() async {
        guard !saving, savedNumber == nil else { return }
        saving = true
        let doc = make()
        let number = await DocumentRegistry.captureStructured(type, summary: title, document: doc)
        savedNumber = number
        saving = false
    }
}
