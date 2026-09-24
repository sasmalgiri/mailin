//
//  ImportSurfacesModifier.swift
//  mailin
//
//  A3 + A4 attached as one modifier.
//
//  Not a stylistic choice: `ContentView.body` is already at the Swift
//  type-checker's limit, and adding these two sheets inline tipped it into
//  "unable to type-check this expression in reasonable time". A modifier gives
//  the checker a boundary to work within, which is the same reason
//  `V9UtilitySheetsModifier` exists in this codebase.
//
//  Both sheets are presented from state that only gets set while their
//  capability is on (`beginImport` starts the import directly otherwise), so
//  with the switches off this modifier is inert.
//

import SwiftUI

struct ImportSurfacesModifier: ViewModifier {
    @Binding var pendingURLs: [URL]?
    @Binding var showQueue: Bool
    let dedupPolicy: DedupPolicy
    let modules: ModuleRegistry
    let onStart: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            // A3: the pre-import review.
            .sheet(isPresented: Binding(get: { pendingURLs != nil },
                                        set: { if !$0 { pendingURLs = nil } })) {
                if let urls = pendingURLs {
                    GuidedImportSheet(
                        urls: urls,
                        dedupPolicy: dedupPolicy,
                        copiesOriginals: true,
                        onStart: { accepted in
                            pendingURLs = nil
                            onStart(accepted)
                        },
                        onCancel: { pendingURLs = nil })
                        .environment(modules)
                }
            }
            // A4: the session import queue.
            .sheet(isPresented: $showQueue) {
                ImportQueueView()
                    .environment(modules)
            }
    }
}
