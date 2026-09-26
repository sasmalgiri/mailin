//
//  ExportReceipt.swift
//  maxmailin
//
//  A8: what an export actually did, kept as a durable record. Every bulk
//  export through `UnifiedExportSections` ends in one of these — requested
//  versus written, whether it was cancelled or failed, the artifact's SHA-256
//  when the writer computed one, and the destination — so "I exported the
//  case" can be checked later against a file rather than remembered.
//
//  Receipts are JSON in Application Support/mailin/exports/receipts, one per
//  export, and are shown by the export overlay when a run finishes. An
//  export that stopped early (cancel, error, disk full) produces a receipt
//  that says so — the failure is never only a vanished progress bar.
//

import Foundation

struct ExportReceipt: Codable, Identifiable, Sendable, Equatable {
    enum Outcome: String, Codable, Sendable {
        case complete
        case truncated      // the free-tier cap wrote fewer than requested
        case cancelled
        case failed
    }

    var id: UUID = UUID()
    var title: String
    var destination: String
    var isFolder: Bool
    var requested: Int?
    var written: Int
    var bytesWritten: Int?
    var outcome: Outcome
    var sha256Hex: String?
    var signaturePath: String?
    var errorMessage: String?
    var startedAt: Date
    var completedAt: Date

    var durationSeconds: Double { completedAt.timeIntervalSince(startedAt) }

    var destinationURL: URL { URL(fileURLWithPath: destination) }

    /// Requested minus written, when both are known and the run did not
    /// finish: what the user did NOT get.
    var shortfall: Int? {
        guard let requested, outcome != .complete else { return nil }
        return max(0, requested - written)
    }

    var verdictLine: String {
        switch outcome {
        case .complete:
            return "Complete — \(written) written"
        case .truncated:
            return "Truncated — \(written) of \(requested ?? written) written (free-tier limit)"
        case .cancelled:
            return "Cancelled — \(written) written before the stop; partial output removed where the writer could"
        case .failed:
            return "Failed — \(written) written before the error"
        }
    }

    /// Plain text, filable without this app.
    func plainText() -> String {
        var lines: [String] = []
        lines.append("mailin export receipt")
        lines.append("Export: \(title)")
        lines.append("Outcome: \(verdictLine)")
        lines.append("Destination: \(destination)\(isFolder ? " (folder)" : "")")
        if let requested { lines.append("Requested: \(requested)") }
        lines.append("Written: \(written)")
        if let bytesWritten { lines.append("Bytes written: \(bytesWritten)") }
        if let sha256Hex { lines.append("SHA-256: \(sha256Hex)") }
        if let signaturePath { lines.append("Signature: \(signaturePath)") }
        if let errorMessage { lines.append("Error: \(errorMessage)") }
        lines.append("Started: \(startedAt.formatted(date: .abbreviated, time: .standard))")
        lines.append("Finished: \(completedAt.formatted(date: .abbreviated, time: .standard)) (\(String(format: "%.1f", durationSeconds)) s)")
        lines.append("Receipt id: \(id.uuidString)")
        return lines.joined(separator: "\n")
    }
}

/// JSON receipts on disk, newest discoverable by modification date.
struct ExportReceiptStore {
    let directory: URL

    static var production: ExportReceiptStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return ExportReceiptStore(directory: base.appendingPathComponent("mailin/exports/receipts", isDirectory: true))
    }

    func save(_ receipt: ExportReceipt) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("export-\(receipt.id.uuidString).json")
        try encoder.encode(receipt).write(to: url, options: .atomic)
        return url
    }

    func load(_ url: URL) throws -> ExportReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportReceipt.self, from: Data(contentsOf: url))
    }

    /// Newest first.
    func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
    }
}
