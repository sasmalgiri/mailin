import SwiftUI

struct IOCEntry: Identifiable, Hashable {
    let id = UUID()
    let type: IOCType
    let value: String
    let source: String
    let emailID: UUID
    let emailSubject: String

    enum IOCType: String, CaseIterable {
        case url = "URL"
        case domain = "Domain"
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
        case email = "Email"
        case fileHash = "Hash"

        var icon: String {
            switch self {
            case .url: return "link"
            case .domain: return "globe"
            case .ipv4, .ipv6: return "network"
            case .email: return "envelope"
            case .fileHash: return "number"
            }
        }
    }
}

struct IOCExtractor {
    static func extract(from emails: [MBOXParser.RawEmail]) -> [IOCEntry] {
        var results: [IOCEntry] = []
        var seen = Set<String>()

        for email in emails {
            let subject = email.headers["Subject"] ?? "(No Subject)"
            let allText = email.plainBody + "\n" + email.htmlBody + "\n" +
                email.headers.values.joined(separator: "\n")

            extractURLs(from: allText, emailID: email.id, subject: subject, seen: &seen, results: &results)
            extractIPs(from: allText, emailID: email.id, subject: subject, seen: &seen, results: &results)
            extractEmails(from: allText, emailID: email.id, subject: subject, seen: &seen, results: &results)
            extractDomains(from: email, seen: &seen, results: &results)
            extractHashes(from: allText, emailID: email.id, subject: subject, seen: &seen, results: &results)
        }
        return results
    }

    private static func extractURLs(from text: String, emailID: UUID, subject: String, seen: inout Set<String>, results: inout [IOCEntry]) {
        let pattern = #"https?://[^\s<>\"\');\]}{]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let url = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            let key = "url:\(url.lowercased())"
            if !seen.contains(key) {
                seen.insert(key)
                results.append(IOCEntry(type: .url, value: url, source: "Body", emailID: emailID, emailSubject: subject))
            }
        }
    }

    private static func extractIPs(from text: String, emailID: UUID, subject: String, seen: inout Set<String>, results: inout [IOCEntry]) {
        let ipv4 = #"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b"#
        if let regex = try? NSRegularExpression(pattern: ipv4) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let ip = String(text[range])
                if ip == "0.0.0.0" || ip == "127.0.0.1" || ip.hasPrefix("255.") { continue }
                let key = "ipv4:\(ip)"
                if !seen.contains(key) {
                    seen.insert(key)
                    results.append(IOCEntry(type: .ipv4, value: ip, source: "Headers/Body", emailID: emailID, emailSubject: subject))
                }
            }
        }

        let ipv6 = #"\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b"#
        if let regex = try? NSRegularExpression(pattern: ipv6) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let ip = String(text[range])
                let key = "ipv6:\(ip.lowercased())"
                if !seen.contains(key) {
                    seen.insert(key)
                    results.append(IOCEntry(type: .ipv6, value: ip, source: "Headers/Body", emailID: emailID, emailSubject: subject))
                }
            }
        }
    }

    private static func extractEmails(from text: String, emailID: UUID, subject: String, seen: inout Set<String>, results: inout [IOCEntry]) {
        let pattern = #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let addr = String(text[range]).lowercased()
            let key = "email:\(addr)"
            if !seen.contains(key) {
                seen.insert(key)
                results.append(IOCEntry(type: .email, value: addr, source: "Headers/Body", emailID: emailID, emailSubject: subject))
            }
        }
    }

    private static func extractDomains(from email: MBOXParser.RawEmail, seen: inout Set<String>, results: inout [IOCEntry]) {
        let subject = email.headers["Subject"] ?? "(No Subject)"
        for domain in email.domains {
            let key = "domain:\(domain.lowercased())"
            if !seen.contains(key) {
                seen.insert(key)
                results.append(IOCEntry(type: .domain, value: domain, source: "Headers", emailID: email.id, emailSubject: subject))
            }
        }
    }

    private static func extractHashes(from text: String, emailID: UUID, subject: String, seen: inout Set<String>, results: inout [IOCEntry]) {
        let md5 = #"\b[a-fA-F0-9]{32}\b"#
        let sha256 = #"\b[a-fA-F0-9]{64}\b"#
        for pattern in [md5, sha256] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let hash = String(text[range]).lowercased()
                let key = "hash:\(hash)"
                if !seen.contains(key) {
                    seen.insert(key)
                    results.append(IOCEntry(type: .fileHash, value: hash, source: "Body", emailID: emailID, emailSubject: subject))
                }
            }
        }
    }

    static func exportAsCSV(_ entries: [IOCEntry]) -> String {
        func csvEscape(_ s: String) -> String {
            var v = s
            if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "") + "\""
        }
        var csv = "Type,Value,Source,Email Subject\n"
        for entry in entries {
            csv += "\(csvEscape(entry.type.rawValue)),\(csvEscape(entry.value)),\(csvEscape(entry.source)),\(csvEscape(entry.emailSubject))\n"
        }
        return csv
    }
}

struct IOCExtractorView: View {
    let emails: [MBOXParser.RawEmail]
    @State private var entries: [IOCEntry] = []
    @State private var isExtracting = false
    @State private var filterType: IOCEntry.IOCType?
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredEntries: [IOCEntry] {
        var result = entries
        if let filter = filterType {
            result = result.filter { $0.type == filter }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.value.lowercased().contains(q) || $0.emailSubject.lowercased().contains(q) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("IOC Extraction")
                        .font(.headline)
                    Text("Indicators of Compromise from \(emails.count) emails")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !entries.isEmpty {
                    Button("Export CSV") { exportCSV() }
                        .buttonStyle(.bordered)
                }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
            .padding()
            Divider()

            if isExtracting {
                VStack { ProgressView("Extracting IOCs..."); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack { Spacer(); Text("No IOCs extracted yet"); Spacer() }
            } else {
                filterChips
                Divider()
                #if os(macOS)
                TextField("Search IOCs...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                #endif
                List(filteredEntries) { entry in
                    HStack {
                        Image(systemName: entry.type.icon)
                            .frame(width: 24)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.value)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Text("\(entry.type.rawValue) • \(entry.emailSubject)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button { copyToClipboard(entry.value) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }
                }
            }
        }
        .task { await extract() }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chipButton("All", count: entries.count, selected: filterType == nil) { filterType = nil }
                ForEach(IOCEntry.IOCType.allCases, id: \.self) { type in
                    let count = entries.filter { $0.type == type }.count
                    if count > 0 {
                        chipButton("\(type.rawValue)", count: count, selected: filterType == type) { filterType = type }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chipButton(_ label: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(label) (\(count))")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func extract() async {
        isExtracting = true
        let emailsCopy = emails
        let result = await Task.detached { IOCExtractor.extract(from: emailsCopy) }.value
        entries = result
        isExtracting = false
    }

    private func exportCSV() {
        let csv = IOCExtractor.exportAsCSV(filteredEntries)
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ioc_indicators.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
