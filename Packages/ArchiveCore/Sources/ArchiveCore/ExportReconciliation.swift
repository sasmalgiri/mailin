//
//  ExportReconciliation.swift
//  ArchiveCore
//
//  Five jobs OUT-04 (open item closed in plan v4 §13.8 step 6, COMP-16):
//  "the export is verified" meant, until now, that the bytes on disk are
//  the bytes that were written (`ExportInventory.verify`). This goes one
//  step further and asks whether what was written still SAYS what the
//  archive says: every output file the inventory ties to a message is
//  parsed back with the same readers an import would use and compared,
//  field by field, with the archive's record — sender, recipients, date,
//  subject, body words, attachment names and attachment bytes. A file that
//  parses to something else is named with the fields that differ.
//
//  Content, not bytes: an .eml re-rendered from a PST message has different
//  bytes from the source but the same content; that is a match here and a
//  difference for the byte inventory — the two statements stay apart.
//

import Foundation

enum ExportReconciliation {

    struct Mismatch: Sendable, Equatable {
        let path: String
        let differences: [String]
    }

    struct Report: Sendable, Equatable {
        /// Files the inventory ties to a message record and that could be parsed.
        var checked = 0
        var matching = 0
        var mismatches: [Mismatch] = []
        /// Files that could not be parsed back as a message (with the reason).
        var unparsed: [String] = []
        /// Files whose message record is no longer in the archive (or listed without one).
        var withoutRecord = 0
        /// Inventory files of a kind this check does not parse (reports, PST, mbox of many).
        var notApplicable = 0

        var isClean: Bool { mismatches.isEmpty && unparsed.isEmpty && checked > 0 && matching == checked }
    }

    /// Re-parse each per-message output file the inventory lists and compare
    /// it with `records[emailID]`. Full, never sampled.
    static func reconcile(folder: URL, records: [UUID: MBOXParser.RawEmail]) throws -> Report {
        let inventory = try ExportInventory.load(folder: folder)
        var report = Report()
        for file in inventory.files {
            let url = folder.appendingPathComponent(file.path)
            let ext = url.pathExtension.lowercased()
            guard ext == "eml" || ext == "msg" else { report.notApplicable += 1; continue }
            guard let idString = file.emailID, let id = UUID(uuidString: idString), let source = records[id] else { report.withoutRecord += 1; continue }
            let output: MBOXParser.RawEmail
            do {
                if ext == "msg" {
                    output = try MSGParser.parse(data: Data(contentsOf: url))
                } else {
                    let data = try Data(contentsOf: url)
                    guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                        report.unparsed.append("\(file.path): text encoding not recognised"); continue
                    }
                    output = try MBOXParser.processRawMessage(raw, senderEmail: "")
                }
            } catch {
                report.unparsed.append("\(file.path): \(error.localizedDescription)"); continue
            }
            defer { for a in output.attachments { if let u = a.fileURL { try? FileManager.default.removeItem(at: u) } } }
            report.checked += 1
            let differences = differences(output: output, source: source)
            if differences.isEmpty { report.matching += 1 } else { report.mismatches.append(Mismatch(path: file.path, differences: differences)) }
        }
        return report
    }

    /// The fields in which the re-parsed output disagrees with the archive's record.
    static func differences(output: MBOXParser.RawEmail, source: MBOXParser.RawEmail) -> [String] {
        var out: [String] = []
        func compare(_ name: String, _ a: String, _ b: String) { if a != b { out.append(name) } }
        compare("subject", collapse(output.headers["Subject"]), collapse(source.headers["Subject"]))
        compare("from", addresses(output.headers["From"]), addresses(source.headers["From"]))
        compare("to", addresses(output.headers["To"]), addresses(source.headers["To"]))
        compare("cc", addresses(output.headers["Cc"] ?? output.headers["CC"]), addresses(source.headers["Cc"] ?? source.headers["CC"]))
        if let a = output.headers["Message-ID"], let b = source.headers["Message-ID"], !a.isEmpty, !b.isEmpty {
            compare("message-id", collapse(a), collapse(b))
        }
        compare("date", dateKey(output.headers["Date"], output.timestamp), dateKey(source.headers["Date"], source.timestamp))
        // A record that holds no body (a located message kept header-only, its
        // bytes streamed from the source at export time) has nothing to disagree with.
        let sourceBody = bodyKey(source)
        if !sourceBody.isEmpty { compare("body", bodyKey(output), sourceBody) }
        let outputNames = output.attachments.map { collapse($0.filename) }.sorted()
        let sourceNames = source.attachments.map { collapse($0.filename) }.sorted()
        if outputNames != sourceNames { out.append("attachments") }
        else if !output.attachments.isEmpty {
            let outputHashes = Set(output.attachments.enumerated().compactMap { i, a in AttachmentHydrator.data(for: a, index: i, email: output).map(ExportFolderManifest.hex) })
            let sourceHashes = Set(source.attachments.enumerated().compactMap { i, a in AttachmentHydrator.data(for: a, index: i, email: source).map(ExportFolderManifest.hex) })
            if outputHashes != sourceHashes { out.append("attachment bytes") }
        }
        return out
    }

    // MARK: Normalisation (what counts as the same content)

    static func collapse(_ s: String?) -> String {
        (s ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    /// Addresses only, lower-cased and sorted: "Ann <a@x.com>" and "a@x.com" agree.
    static func addresses(_ header: String?) -> String {
        guard let header, !header.isEmpty else { return "" }
        var found: [String] = []
        for piece in header.components(separatedBy: ",") {
            if let open = piece.lastIndex(of: "<"), let close = piece[open...].firstIndex(of: ">") {
                found.append(String(piece[piece.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased())
            } else {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty { found.append(trimmed) }
            }
        }
        return found.sorted().joined(separator: ",")
    }

    /// The minute the message carries, from the Date header or the stored
    /// timestamp (RFC 2822 or ISO 8601); unparsable values compare as text.
    static func dateKey(_ header: String?, _ timestamp: String) -> String {
        for candidate in [header ?? "", timestamp] where !candidate.isEmpty {
            if let date = parseDate(candidate) { return String(Int(date.timeIntervalSince1970 / 60)) }
        }
        return collapse(header ?? timestamp)
    }

    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let trimmed = text.replacingOccurrences(of: "\\s*\\(.*\\)$", with: "", options: .regularExpression)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    /// The words of the body: the plain part when there is one, otherwise the HTML with tags removed.
    static func bodyKey(_ email: MBOXParser.RawEmail) -> String {
        let text = email.plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? email.htmlBody.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            : email.plainBody
        return collapse(text)
    }
}
