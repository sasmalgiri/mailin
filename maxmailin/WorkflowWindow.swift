//
//  WorkflowWindow.swift
//  maxmailin
//
//  Opens a guided workflow run in its OWN window on macOS (movable, resizable,
//  sits beside the main window and beside the tool windows a step launches) —
//  the same treatment every other tool gets via ToolWindowPresenter. On iOS,
//  where there are no free-floating windows, the caller falls back to a sheet:
//  open(...) returns false so the caller can present its own sheet instead.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

enum WorkflowWindow {
    /// Present a workflow run in its own window.
    /// - Returns: `true` if a window was opened (macOS); `false` on iOS, where
    ///   the caller should present a sheet instead.
    @MainActor
    @discardableResult
    static func open(
        definition: WorkflowDefinition,
        resumeWF: String? = nil,
        startVariant: SQLiteEmailStore.StoredVariant? = nil,
        onOpenDestination: @escaping (HubDestination) -> Void,
        onClose: @escaping () -> Void = {}
    ) -> Bool {
        #if os(macOS)
        // Resumed runs key on their WF number so each distinct run gets its own
        // window; a fresh run keys on the recipe name (re-clicking focuses it).
        let title = resumeWF.map { "Workflow \($0)" } ?? "Job — \(definition.name)"
        ToolWindowPresenter.shared.open(title: title,
                                        size: CGSize(width: 920, height: 800)) {
            WorkflowRunnerView(
                definition: definition,
                resumeWF: resumeWF,
                startVariant: startVariant,
                // Opening a step's tool now opens a SIBLING window — the
                // workflow window stays put, so the user keeps their place.
                onOpenDestination: onOpenDestination,
                onClose: {
                    onClose()
                    ToolWindowPresenter.shared.close(title: title)
                }
            )
        }
        return true
        #else
        return false
        #endif
    }
}
