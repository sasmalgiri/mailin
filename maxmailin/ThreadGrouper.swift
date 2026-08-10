import Foundation

struct EmailThread: Identifiable {
    let id: String
    let subject: String
    let root: MBOXParser.RawEmail
    let replies: [MBOXParser.RawEmail]

    /// Every message in the thread (root first). Named `members` — not
    /// "allEmails" — because it is a bounded per-thread list, never a corpus.
    var members: [MBOXParser.RawEmail] { [root] + replies }
    var count: Int { members.count }
    var latestTimestamp: String { members.map(\.timestamp).max() ?? root.timestamp }
}

struct ThreadGrouper {
    static func group(_ emails: [MBOXParser.RawEmail]) -> [EmailThread] {
        var threadMap: [String: [MBOXParser.RawEmail]] = [:]

        for email in emails {
            let key = normalizedThreadKey(for: email)
            threadMap[key, default: []].append(email)
        }

        let isoFormatter = ISO8601DateFormatter()
        return threadMap.compactMap { key, members in
            let sorted = members.sorted {
                ($0.timestamp) < ($1.timestamp)
            }
            guard let root = sorted.first else { return nil }
            let subject = root.headers["Subject"] ?? "(No Subject)"
            return EmailThread(
                id: key,
                subject: subject,
                root: root,
                replies: Array(sorted.dropFirst())
            )
        }
        .sorted {
            isoFormatter.date(from: $0.latestTimestamp) ?? .distantPast >
            isoFormatter.date(from: $1.latestTimestamp) ?? .distantPast
        }
    }

    private static func normalizedThreadKey(for email: MBOXParser.RawEmail) -> String {
        if let tid = email.threadID, !tid.isEmpty {
            return tid
        }
        let subject = normalizeSubject(email.headers["Subject"] ?? "")
        if !subject.isEmpty {
            return "subj:" + subject.lowercased()
        }
        return "single:" + email.id.uuidString
    }

    /// Shared with ThreadKeyDeriver (Part L) so persisted subject-fallback
    /// thread keys agree with the legacy visible-page grouping.
    static func normalizeSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["re:", "fwd:", "fw:", "re[", "fwd["]
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for prefix in prefixes {
                if lower.hasPrefix(prefix) {
                    if prefix.hasSuffix("[") {
                        if let close = s.firstIndex(of: "]") {
                            let afterClose = s.index(after: close)
                            if afterClose < s.endIndex && s[afterClose] == ":" {
                                s = String(s[s.index(after: afterClose)...]).trimmingCharacters(in: .whitespaces)
                            } else {
                                s = String(s[afterClose...]).trimmingCharacters(in: .whitespaces)
                            }
                        } else {
                            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                        }
                    } else {
                        s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    }
                    changed = true
                    break
                }
            }
        }
        return s
    }
}
