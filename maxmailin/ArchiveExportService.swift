//
//  ArchiveExportService.swift
//  maxmailin
//
//  Stage 5 Wave 2A (v2-core-cutover): the streaming export authority. Every bulk
//  export accepts an `ArchiveSelectionScope` (or query) and is written
//  INCREMENTALLY from a bounded stream — a "Select All → export" over a million
//  messages never first materializes a giant `[RawEmail]`. Progress, counts and
//  cancellation are reported; a receipt-style summary is returned.
//

import Foundation

enum ArchiveExportFormat: Sendable {
    case csvSummaries      // id,date,from,to,subject
    case jsonSummaries     // array of summary objects
    case eml               // full RFC822 per message, concatenated with separators
}

struct ArchiveExportResult: Sendable, Equatable {
    var recordsWritten: Int
    var bytesWritten: Int
    var completed: Bool
    var cancelled: Bool
}

@MainActor
final class ArchiveExportService {
    static let shared = ArchiveExportService(archive: .shared)

    private let archive: ArchiveDataService
    init(archive: ArchiveDataService) { self.archive = archive }

    /// Stream-export `scope` in `format` to `url`, writing incrementally.
    /// `onProgress` is called after each bounded batch. Returns a receipt.
    @discardableResult
    func export(scope: ArchiveSelectionScope,
                format: ArchiveExportFormat,
                to url: URL,
                batchSize: Int = 200,
                onProgress: (@MainActor (Int) -> Void)? = nil) async throws -> ArchiveExportResult {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var records = 0, bytes = 0, firstJSON = true, cancelled = false
        func write(_ s: String) throws {
            let d = Data(s.utf8); try handle.write(contentsOf: d); bytes += d.count
        }

        if format == .csvSummaries { try write("id,date,from,to,subject\n") }
        if format == .jsonSummaries { try write("[") }

        for try await batch in archive.streamSelected(scope: scope, batchSize: batchSize) {
            if Task.isCancelled { cancelled = true; break }
            for email in batch {
                switch format {
                case .csvSummaries:
                    let date = MBOXParser.parseDate(email.headers["Date"]).map { ISO8601DateFormatter().string(from: $0) } ?? ""
                    let row = [email.id.uuidString, date,
                               email.headers["From"] ?? "", email.headers["To"] ?? "",
                               email.headers["Subject"] ?? ""].map(Self.csvField).joined(separator: ",")
                    try write(row + "\n")
                case .jsonSummaries:
                    let obj: [String: String] = [
                        "id": email.id.uuidString,
                        "from": email.headers["From"] ?? "",
                        "subject": email.headers["Subject"] ?? "",
                        "date": email.headers["Date"] ?? ""
                    ]
                    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
                    if !firstJSON { try write(",") }
                    firstJSON = false
                    try handle.write(contentsOf: data); bytes += data.count
                case .eml:
                    let eml = email.rawSource.isEmpty
                        ? "Subject: \(email.headers["Subject"] ?? "")\n\n\(email.plainBody)"
                        : email.rawSource
                    try write("\n--- MESSAGE \(email.id.uuidString) ---\n")
                    try write(eml)
                }
                records += 1
            }
            onProgress?(records)
        }

        if format == .jsonSummaries { try write("]") }
        return ArchiveExportResult(recordsWritten: records, bytesWritten: bytes, completed: !cancelled, cancelled: cancelled)
    }

    private static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
