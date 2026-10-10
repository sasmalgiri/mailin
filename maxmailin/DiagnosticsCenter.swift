@testable import ArchiveCore
//
//  DiagnosticsCenter.swift
//  maxmailin
//
//  §3-S5: crash, hang and disk-write diagnostics from Apple's MetricKit, kept
//  ON THE DEVICE (offline-first: nothing is uploaded). They feed "Copy
//  diagnostics" (engine trips, Safe Mode, the Health page) so a user can choose
//  to send them. No third-party SDK; MetricKit delivers a crash report on the
//  next launch.
//

import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

final class DiagnosticsCenter: NSObject, @unchecked Sendable {
    static let shared = DiagnosticsCenter()

    /// Newest-first cap on stored payload files. A diagnostics folder, not
    /// user data: the oldest reports are dropped.
    static let keepFiles = 20

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Call once at launch.
    static func start() {
        #if canImport(MetricKit)
        MXMetricManager.shared.add(shared)
        #endif
    }

    func store(_ json: Data, kind: String) {
        let fm = FileManager.default
        let dir = Self.directory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try json.write(to: dir.appendingPathComponent("\(stamp)-\(kind).json"), options: .atomic)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let sorted = files.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            for old in sorted.dropFirst(Self.keepFiles) { try? fm.removeItem(at: old) }
        } catch {
            // Diagnostics must never disturb the app.
        }
    }

    /// Counts of stored reports by kind, for diagnostics text and Health.
    func summary() -> (crashes: Int, hangs: Int, diskWrites: Int, other: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        var c = 0, h = 0, d = 0, o = 0
        for f in files {
            if f.contains("-crash") { c += 1 } else if f.contains("-hang") { h += 1 }
            else if f.contains("-diskwrite") { d += 1 } else { o += 1 }
        }
        return (c, h, d, o)
    }

    func summaryText() -> String {
        let s = summary()
        return "On-device diagnostics (MetricKit): \(s.crashes) crash, \(s.hangs) hang, \(s.diskWrites) disk-write, \(s.other) other report(s) in \(Self.directory.path)"
    }

    /// The raw stored reports, for "Copy diagnostics" with details.
    func latestReportsText(limit: Int = 3) -> String {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
        return files.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { "--- \(url.lastPathComponent)\n\($0)" }
        }.joined(separator: "\n\n")
    }
}

#if canImport(MetricKit)
extension DiagnosticsCenter: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let kind: String
            if !(payload.crashDiagnostics ?? []).isEmpty { kind = "crash" }
            else if !(payload.hangDiagnostics ?? []).isEmpty { kind = "hang" }
            else if !(payload.diskWriteExceptionDiagnostics ?? []).isEmpty { kind = "diskwrite" }
            else { kind = "diagnostic" }
            store(payload.jsonRepresentation(), kind: kind)
        }
    }

    #if os(iOS)
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { store(payload.jsonRepresentation(), kind: "metrics") }
    }
    #endif
}
#endif
