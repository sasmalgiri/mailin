//
//  SmartAutoTaggerView.swift
//  mailin
//
//  Displays NLP-based auto-tag suggestions for email archives.
//

import SwiftUI

struct SmartAutoTaggerView: View {
    // v2: bounded most-recent working set from the store (no injected corpus).
    @State private var workingSet: [MBOXParser.RawEmail] = []
    var isPresented: Binding<Bool>?
    @StateObject private var tagger = SmartAutoTagger()
    @State private var selectedTag: String?
    @Environment(\.dismiss) private var envDismiss

    private var allUniqueTags: [(tag: String, count: Int)] {
        var tagCounts: [String: Int] = [:]
        for (_, suggestions) in tagger.suggestedTags {
            for suggestion in suggestions {
                tagCounts[suggestion.tag, default: 0] += 1
            }
        }
        return tagCounts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var visibleEmails: [MBOXParser.RawEmail] {
        guard let selectedTag = selectedTag else { return workingSet }
        let matchingIDs = Set(
            tagger.suggestedTags
                .filter { (_, suggestions) in suggestions.contains { $0.tag == selectedTag } }
                .map(\.key)
        )
        return workingSet.filter { matchingIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "tag.fill")
                    .foregroundColor(AppColors.primary)
                Text("Smart Auto-Tagger")
                    .font(Typography.headline)
                Spacer()
                if isPresented != nil {
                    Button("Done") { closeSheet() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(Spacing.medium)

            Divider()

            if tagger.isProcessing {
                VStack(spacing: Spacing.medium) {
                    Spacer()
                    ProgressView(value: Double(tagger.processedCount), total: Double(max(tagger.totalCount, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                    Text("Analyzing \(tagger.processedCount)/\(tagger.totalCount) emails...")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                    Spacer()
                }
                .padding(Spacing.medium)
            } else if tagger.suggestedTags.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "tag",
                        title: "No Tags Generated",
                        message: "Import an email archive to generate smart tag suggestions."
                    )
                    Button("Generate Tags") { startTagging() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, Spacing.medium)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    // Tag cloud summary
                    tagCloudSection
                        .padding(Spacing.medium)

                    Divider()

                    // Email list with tags
                    List {
                        ForEach(visibleEmails) { email in
                            emailTagRow(email)
                        }
                    }
                }
            }
        }
        .onAppear { startTagging() }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    // MARK: - Tag Cloud

    private var tagCloudSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Text("\(allUniqueTags.count) unique tags across \(tagger.suggestedTags.count) emails")
                    .font(Typography.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if selectedTag != nil {
                    Button("Clear Filter") { selectedTag = nil }
                        .font(Typography.caption1)
                        .buttonStyle(.plain)
                        .foregroundColor(AppColors.primary)
                }
            }

            Label {
                Text("Tags are suggested using NLP analysis of email content, subjects, and metadata. Review and approve suggestions before applying — automated tags should be verified for accuracy.")
                    .font(Typography.caption1)
            } icon: {
                Image(systemName: "tag.fill")
                    .foregroundColor(.blue)
            }
            .padding(Spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(CornerRadius.small)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xxSmall) {
                    ForEach(allUniqueTags, id: \.tag) { item in
                        tagChip(tag: item.tag, count: item.count, isSelected: selectedTag == item.tag) {
                            selectedTag = selectedTag == item.tag ? nil : item.tag
                        }
                    }
                }
            }
        }
    }

    private func tagChip(tag: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xxxSmall) {
                Text(tag)
                    .font(Typography.caption1)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text("(\(count))")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.horizontal, Spacing.xSmall)
            .padding(.vertical, Spacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.round)
                    .fill(isSelected ? tagColor(for: tag).opacity(0.15) : AppColors.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.round)
                    .stroke(isSelected ? tagColor(for: tag).opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Email Row

    private func emailTagRow(_ email: MBOXParser.RawEmail) -> some View {
        let suggestions = tagger.suggestedTags[email.id] ?? []

        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text(email.headers["Subject"] ?? "(No Subject)")
                .font(Typography.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)

            HStack(spacing: Spacing.xSmall) {
                Text(email.headers["From"] ?? "Unknown")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
                Spacer()
                if let dateStr = email.headers["Date"], let date = MBOXParser.parseDate(dateStr) {
                    Text(formatDate(date))
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xxxSmall) {
                        ForEach(suggestions) { suggestion in
                            tagPill(suggestion)
                        }
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xxSmall)
        .accessibilityElement(children: .combine)
    }

    private func tagPill(_ suggestion: SmartAutoTagger.TagSuggestion) -> some View {
        HStack(spacing: 2) {
            Circle()
                .fill(tagColor(for: suggestion.tag))
                .frame(width: 6, height: 6)
            Text(suggestion.tag)
                .font(Typography.caption2)
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.round)
                .fill(tagColor(for: suggestion.tag).opacity(0.1))
        )
        .help(Text(verbatim: "Confidence: \(String(format: "%.0f%%", suggestion.confidence * 100)) — \(suggestion.reason)"))
    }

    // MARK: - Helpers

    private func tagColor(for tag: String) -> Color {
        let hash = abs(tag.hashValue)
        let colors: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .mint, .cyan, .red]
        return colors[hash % colors.count]
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func startTagging() {
        guard !tagger.isProcessing && tagger.suggestedTags.isEmpty else { return }
        Task {
            if workingSet.isEmpty {
                var acc: [MBOXParser.RawEmail] = []
                let stream = ArchiveDataService.shared.streamFullEmails(query: .all, batchSize: 200)
                do { for try await b in stream { acc.append(contentsOf: b); if acc.count >= 2000 { break } } } catch { }
                workingSet = Array(acc.prefix(2000))
            }
            await tagger.generateTags(for: workingSet)
        }
    }
}
