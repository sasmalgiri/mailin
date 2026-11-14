//
//  ImportScriptHook.swift
//  ArchiveCore
//
//  3.1 S5: the app's import-time scripts. Called with every batch the store
//  actually committed (after the FTS write), so a script can tag, enrich or
//  set aside new mail. Set-aside mail is moved to Trash by the app — never
//  dropped before insert — so source ordinals, checkpoints and the receipt
//  stay exact and the step is reversible. nil = no scripts (the default).
//

import Foundation

enum ImportScriptHook {
    /// Returns what the scripts did to the batch: script label → change kind → count.
    nonisolated(unsafe) static var handler: (@Sendable ([MBOXParser.RawEmail], String) async -> [String: [String: Int]])?
}
