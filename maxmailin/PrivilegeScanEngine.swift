@testable import ArchiveCore
//
//  PrivilegeScanEngine.swift
//  maxmailin
//
//  §3-L9 (switch: `v3PrivilegeScan`). The privilege scan over the WHOLE
//  scope. Same detector (ForensicManager.detectPrivilege); flags are
//  collected across every batch and published once, so the "Privileged"
//  filters and badges cover the archive rather than the newest 2,000.
//

import Foundation

@MainActor
enum PrivilegeScanEngine {
    struct Progress: Codable, Sendable { var emails = 0 }

    @discardableResult
    static func scan(query: EmailQuery) async throws -> (flagged: Int, receipt: ScopeJobReceipt) {
        // Only the emails actually scanned change: flags elsewhere in the
        // archive (a narrower scope, or a cancelled run) are kept. Replacing
        // the whole dictionary erased every flag outside the scope.
        let forensic = ForensicManager.shared
        var flags = forensic.privilegeFlags
        var flaggedInScope = 0
        let result = try await ScopeJob.run(
            key: "privilege.scan", title: String(localized: "Privilege scan"),
            capability: .v3PrivilegeScan, query: query, resumable: false, initialState: Progress()
        ) { state, batch in
            for email in batch {
                let r = ForensicManager.detectPrivilege(for: email)
                if r.isLikelyPrivileged {
                    flags[email.id] = r.indicators
                    flaggedInScope += 1
                } else {
                    flags[email.id] = nil
                }
            }
            state.emails += batch.count
        }
        forensic.privilegeFlags = flags
        ScopeJobEnvironment.logAction("Privilege Scan",
                           detail: "Scanned \(result.receipt.processed) emails, flagged \(flaggedInScope) as potentially privileged — scope: \(result.receipt.scope); \(result.receipt.coverageLine)")
        return (flaggedInScope, result.receipt)
    }

    /// The call every privilege-scan button makes: the whole-scope engine
    /// when its switch is on, the previous scan of `loaded` otherwise.
    static func run(modules: ModuleRegistry?, query: EmailQuery, loaded: [MBOXParser.RawEmail],
                    then done: @escaping @MainActor () -> Void = {}) {
        guard modules?.isOn(.v3PrivilegeScan) ?? false else {
            ForensicManager.shared.runPrivilegeScan(on: loaded)
            done()
            return
        }
        Task { @MainActor in
            do { try await scan(query: query) } catch {
                // The previous engine still answers for the loaded emails.
                EngineGuard.recordFallback(.v3PrivilegeScan, error: error)
                ForensicManager.shared.runPrivilegeScan(on: loaded)
            }
            done()
        }
    }
}
