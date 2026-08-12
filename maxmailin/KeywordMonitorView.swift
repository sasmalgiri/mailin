//
//  KeywordMonitorView.swift
//  mailin
//
//  Keyword watchlist that scans email archives for specific terms.
//

import SwiftUI

// MARK: - Keyword Monitor Engine

struct KeywordMonitor {

    struct WatchedKeyword: Identifiable, Codable, Hashable, Sendable {
        let id: UUID
        let keyword: String
        let isRegex: Bool
        let caseSensitive: Bool
        let createdAt: Date

        init(id: UUID = UUID(), keyword: String, isRegex: Bool = false, caseSensitive: Bool = false, createdAt: Date = Date()) {
            self.id = id
            self.keyword = keyword
            self.isRegex = isRegex
            self.caseSensitive = caseSensitive
            self.createdAt = createdAt
        }
    }

    struct KeywordMatch: Identifiable {
        let id: UUID
        let keyword: WatchedKeyword
        let email: MBOXParser.RawEmail
        let matchCount: Int
        let contextSnippet: String

        init(id: UUID = UUID(), keyword: WatchedKeyword, email: MBOXParser.RawEmail, matchCount: Int, contextSnippet: String) {
            self.id = id
            self.keyword = keyword
            self.email = email
            self.matchCount = matchCount
            self.contextSnippet = contextSnippet
        }
    }

    static func scan(emails: [MBOXParser.RawEmail], keywords: [WatchedKeyword]) -> [KeywordMatch] {
        var matches: [KeywordMatch] = []

        for keyword in keywords {
            for email in emails {
                let subject = email.headers["Subject"] ?? ""
                let body = bodyText(for: email)
                let searchText = "\(subject) \(body)"

                guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                let matchResult = countMatches(in: searchText, keyword: keyword)
                guard matchResult.count > 0 else { continue }

                let snippet = extractSnippet(from: searchText, keyword: keyword, maxLength: 100)

                matches.append(KeywordMatch(
                    keyword: keyword,
                    email: email,
                    matchCount: matchResult.count,
                    contextSnippet: snippet
                ))
            }
        }

        return matches.sorted { $0.matchCount > $1.matchCount }
    }

    private static func countMatches(in text: String, keyword: WatchedKeyword) -> (count: Int, ranges: [Range<String.Index>]) {
        if keyword.isRegex {
            return countRegexMatches(in: text, pattern: keyword.keyword, caseSensitive: keyword.caseSensitive)
        } else {
            return countStringMatches(in: text, searchTerm: keyword.keyword, caseSensitive: keyword.caseSensitive)
        }
    }

    private static func countStringMatches(in text: String, searchTerm: String, caseSensitive: Bool) -> (count: Int, ranges: [Range<String.Index>]) {
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var count = 0
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            guard let range = text.range(of: searchTerm, options: options, range: searchStart..<text.endIndex) else { break }
            count += 1
            ranges.append(range)
            searchStart = range.upperBound
        }

        return (count, ranges)
    }

    private static let maxRegexPatternLength = 500

    private static func countRegexMatches(in text: String, pattern: String, caseSensitive: Bool) -> (count: Int, ranges: [Range<String.Index>]) {
        guard pattern.count <= maxRegexPatternLength else { return (0, []) }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return (0, [])
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let results = regex.matches(in: text, range: nsRange)
        let ranges: [Range<String.Index>] = results.compactMap { result in
            Range(result.range, in: text)
        }

        return (results.count, ranges)
    }

    private static func extractSnippet(from text: String, keyword: WatchedKeyword, maxLength: Int) -> String {
        if keyword.isRegex {
            guard keyword.keyword.count <= maxRegexPatternLength else { return String(text.prefix(maxLength)) }
            let regexOptions: NSRegularExpression.Options = keyword.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: keyword.keyword, options: regexOptions) else {
                return String(text.prefix(maxLength))
            }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: nsRange),
                  let range = Range(match.range, in: text) else {
                return String(text.prefix(maxLength))
            }
            return buildSnippetAround(text: text, matchRange: range, maxLength: maxLength)
        } else {
            let options: String.CompareOptions = keyword.caseSensitive ? [] : [.caseInsensitive]
            guard let range = text.range(of: keyword.keyword, options: options) else {
                return String(text.prefix(maxLength))
            }
            return buildSnippetAround(text: text, matchRange: range, maxLength: maxLength)
        }
    }

    private static func buildSnippetAround(text: String, matchRange: Range<String.Index>, maxLength: Int) -> String {
        let matchStart = text.distance(from: text.startIndex, to: matchRange.lowerBound)
        let contextBefore = maxLength / 3
        let snippetStart = max(0, matchStart - contextBefore)
        let startIndex = text.index(text.startIndex, offsetBy: snippetStart)
        let endOffset = min(text.count, snippetStart + maxLength)
        let endIndex = text.index(text.startIndex, offsetBy: endOffset)

        var snippet = String(text[startIndex..<endIndex])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if snippetStart > 0 { snippet = "...\(snippet)" }
        if endOffset < text.count { snippet = "\(snippet)..." }

        return snippet
    }

    private static func bodyText(for email: MBOXParser.RawEmail) -> String {
        if !email.plainBody.isEmpty { return email.plainBody }
        if !email.htmlBody.isEmpty {
            return email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "mailin.keywordMonitor.watchedKeywords"

    static func loadKeywords() -> [WatchedKeyword] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([WatchedKeyword].self, from: data)) ?? []
    }

    static func saveKeywords(_ keywords: [WatchedKeyword]) {
        guard let data = try? JSONEncoder().encode(keywords) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

// MARK: - Keyword Monitor View

struct KeywordMonitorView: View {
    let emails: [MBOXParser.RawEmail]
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss

    @State private var keywords: [KeywordMonitor.WatchedKeyword] = []
    @State private var newKeywordText = ""
    @State private var newKeywordIsRegex = false
    @State private var newKeywordCaseSensitive = false
    @State private var matches: [KeywordMonitor.KeywordMatch] = []
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var selectedKeywordID: UUID?
    @State private var showTutorial = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            #if os(macOS)
            HSplitView {
                keywordPanel
                    .frame(minWidth: 250, idealWidth: 280)
                resultsPanel
                    .frame(minWidth: 350, idealWidth: 400)
            }
            #else
            HStack(spacing: 0) {
                keywordPanel
                resultsPanel
            }
            #endif
        }
        #if os(macOS)
        .toolWindowFrame()
        #endif
        .background(AppColors.backgroundTertiary)
        .featureTutorial(.keywordMonitor, key: "keyword_monitor_tutorial_seen", isPresented: $showTutorial)
        .onAppear {
            keywords = KeywordMonitor.loadKeywords()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.title2)
                    .adaptiveIconGradient(colors: [.orange, .red])
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyword Monitor")
                        .font(Typography.headline)
                    Text("\(emails.count) emails, \(keywords.count) keywords")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
            Spacer()
            TutorialHelpButton(showTutorial: $showTutorial)
            if isPresented != nil {
                Button("Done") { closeSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.backgroundPrimary)
    }

    // MARK: - Keyword Panel

    private var keywordPanel: some View {
        VStack(spacing: Spacing.small) {
            // Add keyword section
            VStack(spacing: Spacing.xSmall) {
                HStack {
                    TextField("Enter keyword or pattern", text: $newKeywordText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addKeyword() }

                    Button("Add") { addKeyword() }
                        .buttonStyle(CompactPrimaryButtonStyle())
                        .disabled(newKeywordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack(spacing: Spacing.medium) {
                    Toggle("Regex", isOn: $newKeywordIsRegex)
                        .font(Typography.caption1)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                    Toggle("Case Sensitive", isOn: $newKeywordCaseSensitive)
                        .font(Typography.caption1)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                    Spacer()
                }
            }
            .padding(Spacing.small)
            .adaptiveCard(cornerRadius: CornerRadius.medium)

            // Keywords list
            if keywords.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "text.magnifyingglass",
                        title: "No Keywords",
                        message: "Add keywords to monitor in your email archive."
                    )
                    Spacer()
                }
            } else {
                List {
                    ForEach(keywords) { keyword in
                        keywordRow(keyword)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedKeywordID = keyword.id
                            }
                    }
                    .onDelete(perform: deleteKeyword)
                }
                .listStyle(.plain)
            }

            // Scan button
            Button {
                scanArchive()
            } label: {
                HStack {
                    if isScanning {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Image(systemName: "magnifyingglass")
                    Text(isScanning ? "Scanning..." : "Scan Archive")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(keywords.isEmpty || isScanning)
            .padding(.horizontal, Spacing.small)
            .padding(.bottom, Spacing.small)
        }
        .background(AppColors.backgroundSecondary)
    }

    private func keywordRow(_ keyword: KeywordMonitor.WatchedKeyword) -> some View {
        HStack(spacing: Spacing.xSmall) {
            VStack(alignment: .leading, spacing: 2) {
                Text(keyword.keyword)
                    .font(Typography.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: Spacing.xSmall) {
                    if keyword.isRegex {
                        Text("REGEX")
                            .font(Typography.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, Spacing.xxSmall)
                            .padding(.vertical, 1)
                            .background(AppColors.info)
                            .cornerRadius(CornerRadius.small)
                    }
                    if keyword.caseSensitive {
                        Text("Aa")
                            .font(Typography.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, Spacing.xxSmall)
                            .padding(.vertical, 1)
                            .background(AppColors.warning)
                            .cornerRadius(CornerRadius.small)
                    }
                }
            }
            Spacer()

            // Match count badge
            let matchCount = matchesForKeyword(keyword.id).count
            if hasScanned && matchCount > 0 {
                Text("\(matchCount)")
                    .font(Typography.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, 2)
                    .background(AppColors.error)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, Spacing.xxxSmall)
        .background(selectedKeywordID == keyword.id ? AppColors.primary.opacity(0.1) : Color.clear)
        .cornerRadius(CornerRadius.small)
    }

    // MARK: - Results Panel

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasScanned {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: "Ready to Scan",
                        message: "Add keywords and press 'Scan Archive' to search your emails."
                    )
                    Spacer()
                }
            } else if isScanning {
                VStack {
                    Spacer()
                    ProgressView("Scanning emails for keywords...")
                        .font(Typography.callout)
                    Spacer()
                }
            } else if matches.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "No Matches",
                        message: "None of your keywords were found in the email archive."
                    )
                    Spacer()
                }
            } else {
                resultsList
            }
        }
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                // Summary
                HStack(spacing: Spacing.medium) {
                    AnimatedStatCard(
                        title: "Total Matches",
                        value: "\(matches.count)",
                        icon: "checkmark.circle.fill",
                        color: .green
                    )
                    AnimatedStatCard(
                        title: "Emails Matched",
                        value: "\(uniqueMatchedEmailCount)",
                        icon: "envelope.fill",
                        color: .blue
                    )
                }

                Label {
                    Text("Total Matches counts every keyword occurrence across all emails. Emails Matched counts unique emails containing at least one keyword. A single email may contain multiple keyword matches.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundColor(.blue)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(CornerRadius.small)

                // Grouped results
                let displayedMatches: [KeywordMonitor.KeywordMatch] = {
                    if let selected = selectedKeywordID {
                        return matchesForKeyword(selected)
                    }
                    return matches
                }()

                let grouped = Dictionary(grouping: displayedMatches, by: { $0.keyword.keyword })
                ForEach(grouped.keys.sorted(), id: \.self) { key in
                    if let group = grouped[key] {
                        VStack(alignment: .leading, spacing: Spacing.xSmall) {
                            HStack {
                                Image(systemName: "text.magnifyingglass")
                                    .foregroundColor(AppColors.primary)
                                Text(key)
                                    .font(Typography.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("\(group.count) matches")
                                    .font(Typography.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, Spacing.xSmall)
                                    .padding(.vertical, 2)
                                    .background(AppColors.primary)
                                    .clipShape(Capsule())
                            }

                            ForEach(group) { match in
                                matchRow(match)
                            }
                        }
                        .cardStyle()
                    }
                }
            }
            .padding(Spacing.medium)
        }
    }

    private func matchRow(_ match: KeywordMonitor.KeywordMatch) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
            HStack {
                Text(match.email.headers["From"] ?? "Unknown")
                    .font(Typography.caption1)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text("\(match.matchCount)x")
                    .font(Typography.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(AppColors.warning)
            }
            Text(match.email.headers["Subject"] ?? "(No Subject)")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .lineLimit(1)
            Text(match.contextSnippet)
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .lineLimit(2)
                .italic()
        }
        .padding(.vertical, Spacing.xxxSmall)
        .padding(.leading, Spacing.small)
    }

    // MARK: - Actions

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private func addKeyword() {
        let trimmed = newKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let keyword = KeywordMonitor.WatchedKeyword(
            keyword: trimmed,
            isRegex: newKeywordIsRegex,
            caseSensitive: newKeywordCaseSensitive
        )
        keywords.append(keyword)
        KeywordMonitor.saveKeywords(keywords)
        newKeywordText = ""
        newKeywordIsRegex = false
        newKeywordCaseSensitive = false
    }

    private func deleteKeyword(at offsets: IndexSet) {
        keywords.remove(atOffsets: offsets)
        KeywordMonitor.saveKeywords(keywords)
    }

    private func scanArchive() {
        isScanning = true
        hasScanned = true
        let emailsCopy = emails
        let keywordsCopy = keywords

        Task.detached {
            let results = KeywordMonitor.scan(emails: emailsCopy, keywords: keywordsCopy)
            await MainActor.run {
                matches = results
                isScanning = false
                // Record this keyword sweep as a numbered document.
                let kwCount = keywordsCopy.count
                let hitCount = results.count
                let body = "KEYWORD SWEEP\nKeywords: \(kwCount)\nMatches: \(hitCount)\nDate: \(Date().formatted(date: .abbreviated, time: .shortened))"
                Task { await DocumentRegistry.captureStructured(.report,
                    summary: "Keyword sweep — \(kwCount) terms, \(hitCount) matches",
                    document: CapturedDocument(title: "Keyword Sweep", sections: [
                      .init(name: "Keyword Sweep", fields: [
                        .init(key: "Keywords", value: "\(kwCount)"),
                        .init(key: "Matches", value: "\(hitCount)")])])) }
            }
        }
    }

    private func matchesForKeyword(_ keywordID: UUID) -> [KeywordMonitor.KeywordMatch] {
        matches.filter { $0.keyword.id == keywordID }
    }

    private var uniqueMatchedEmailCount: Int {
        Set(matches.map { $0.email.id }).count
    }
}
