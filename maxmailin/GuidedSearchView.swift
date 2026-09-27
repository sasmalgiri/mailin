@testable import ArchiveCore
import SwiftUI

/// A7: the advanced-search sheet. Every field compiles to an operator the
/// archive-wide query compiler understands, so what this sheet can express is
/// exactly what `ArchiveQueryCompiler` + SQL/FTS5 can answer — nothing here is
/// filtered in memory. The composed query is shown before it runs, so the
/// operator syntax is learnable from the sheet.
struct GuidedSearchView: View {
    @Binding var searchText: String
    @Binding var isPresented: Bool
    var onSearch: () -> Void

    @State private var whoFrom = ""
    @State private var whoTo = ""
    @State private var aboutWhat = ""
    @State private var exactPhrase = ""
    @State private var anyWords = ""
    @State private var noneOfWords = ""
    @State private var attachmentName = ""
    @State private var sourceFile = ""
    @State private var tag = ""
    @State private var afterDate: Date?
    @State private var beforeDate: Date?
    @State private var hasAttachments = false
    @State private var showAdvanced = false
    @State private var showAfterPicker = false
    @State private var showBeforePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Find Emails", systemImage: "magnifyingglass")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close guided search")
            }

            Text("Answer any of these — leave blank to skip. Every field searches the whole archive.")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    fieldRow(icon: "person", label: "Who sent it?", placeholder: "e.g. john, mom, boss@company.com", text: $whoFrom)
                    fieldRow(icon: "person.2", label: "Who was it sent to?", placeholder: "e.g. me, team, jane@work.com", text: $whoTo)
                    fieldRow(icon: "text.quote", label: "What was the subject about?", placeholder: "e.g. vacation photos, invoice, contract", text: $aboutWhat)

                    dateRow

                    Toggle("Has attachments", isOn: $hasAttachments)
                        .toggleStyle(.switch)

                    DisclosureGroup("More ways to narrow", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            fieldRow(icon: "quote.opening", label: "Exact phrase (anywhere in the text)",
                                     placeholder: "e.g. wire transfer instructions", text: $exactPhrase)
                            fieldRow(icon: "text.word.spacing", label: "Any of these words",
                                     placeholder: "e.g. invoice receipt payment", text: $anyWords)
                            fieldRow(icon: "minus.circle", label: "None of these words",
                                     placeholder: "e.g. newsletter unsubscribe", text: $noneOfWords)
                            fieldRow(icon: "paperclip", label: "Attachment name or type",
                                     placeholder: "e.g. contract.pdf, xlsx, .zip", text: $attachmentName)
                            fieldRow(icon: "tray", label: "From which imported file (folder / source)",
                                     placeholder: "e.g. takeout, Sent.mbox", text: $sourceFile)
                            fieldRow(icon: "tag", label: "With tag or label",
                                     placeholder: "e.g. Important, triage:phish", text: $tag)
                            if !noneOfWords.trimmingCharacters(in: .whitespaces).isEmpty && positiveTerms.isEmpty {
                                Label("\"None of these words\" needs at least one positive word, phrase or subject to exclude from.",
                                      systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.callout)
                }
            }
            .frame(maxHeight: 420)

            Divider()

            HStack {
                let query = buildQuery()
                if !query.isEmpty {
                    Text("Search: \(query)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help("This is the operator query that will run. You can type it directly next time.")
                }
                Spacer()
                Button("Clear") { clearAll() }
                    .buttonStyle(.bordered)
                Button("Search") {
                    searchText = query
                    onSearch()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(query.isEmpty)
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 460)
        #endif
    }

    private var dateRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("After")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let date = afterDate {
                    HStack {
                        Text(date, style: .date)
                            .font(.callout)
                        Button { afterDate = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Clear the After date")
                    }
                } else {
                    Button("Set date...") { showAfterPicker = true }
                        .font(.callout)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Before")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let date = beforeDate {
                    HStack {
                        Text(date, style: .date)
                            .font(.callout)
                        Button { beforeDate = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Clear the Before date")
                    }
                } else {
                    Button("Set date...") { showBeforePicker = true }
                        .font(.callout)
                }
            }
        }
        .popover(isPresented: $showAfterPicker) {
            DatePicker("After", selection: Binding(get: { afterDate ?? Date() }, set: { afterDate = $0; showAfterPicker = false }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
        }
        .popover(isPresented: $showBeforePicker) {
            DatePicker("Before", selection: Binding(get: { beforeDate ?? Date() }, set: { beforeDate = $0; showBeforePicker = false }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
        }
    }

    private func fieldRow(icon: String, label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Query composition

    /// Free-text terms that FTS can exclude from: the phrase and the "any"
    /// words. (Subject/sender operators are SQL predicates, not FTS terms, so
    /// NOT cannot hang off them alone.)
    private var positiveTerms: [String] {
        var terms: [String] = []
        let phrase = exactPhrase.trimmingCharacters(in: .whitespaces)
        if !phrase.isEmpty { terms.append("\"\(phrase.replacingOccurrences(of: "\"", with: ""))\"") }
        let words = anyWords.split(whereSeparator: \.isWhitespace).map(String.init)
        if !words.isEmpty { terms.append(words.count == 1 ? words[0] : "(" + words.joined(separator: " OR ") + ")") }
        return terms
    }

    /// Builds the operator query; pure so the composition rules are testable.
    static func compose(from: String, to: String, subject: String, phrase: String, anyWords: String,
                        noneOfWords: String, attachmentName: String, sourceFile: String, tag: String,
                        hasAttachments: Bool, after: Date?, before: Date?) -> String {
        var parts: [String] = []
        func quoted(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.contains(" ") ? "\"\(t)\"" : t
        }
        if !from.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("from:\(quoted(from))") }
        if !to.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("to:\(quoted(to))") }
        if !subject.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("subject:\(quoted(subject))") }
        if !attachmentName.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("filename:\(quoted(attachmentName))") }
        if !sourceFile.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("source:\(quoted(sourceFile))") }
        if !tag.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("tag:\(quoted(tag))") }
        if hasAttachments && attachmentName.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("has:attachment") }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let after { parts.append("after:\(formatter.string(from: after))") }
        if let before { parts.append("before:\(formatter.string(from: before))") }

        // Free text last: FTS5 Boolean grammar, NOT only when there is
        // something to exclude from.
        var terms: [String] = []
        let p = phrase.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { terms.append("\"\(p.replacingOccurrences(of: "\"", with: ""))\"") }
        let words = anyWords.split(whereSeparator: \.isWhitespace).map(String.init)
        if !words.isEmpty { terms.append(words.count == 1 ? words[0] : "(" + words.joined(separator: " OR ") + ")") }
        var text = terms.joined(separator: " AND ")
        let excluded = noneOfWords.split(whereSeparator: \.isWhitespace).map(String.init)
        if !text.isEmpty, !excluded.isEmpty {
            for word in excluded { text += " NOT \(word)" }
        }
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: " ")
    }

    private func buildQuery() -> String {
        Self.compose(from: whoFrom, to: whoTo, subject: aboutWhat, phrase: exactPhrase, anyWords: anyWords,
                     noneOfWords: noneOfWords, attachmentName: attachmentName, sourceFile: sourceFile, tag: tag,
                     hasAttachments: hasAttachments, after: afterDate, before: beforeDate)
    }

    private func clearAll() {
        whoFrom = ""; whoTo = ""; aboutWhat = ""
        exactPhrase = ""; anyWords = ""; noneOfWords = ""
        attachmentName = ""; sourceFile = ""; tag = ""
        afterDate = nil; beforeDate = nil
        hasAttachments = false
    }
}
