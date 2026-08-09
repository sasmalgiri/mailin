//
//  ThreadStoryView.swift
//  maxmailin
//
//  "Story of this thread": one click on any email reconstructs the whole
//  conversation as a chronological timeline — every entry IS the evidence
//  (subject/from/date/snippet, tappable) — plus an optional on-device AI
//  narrative over exactly those emails (grounded: the model only ever sees
//  the hydrated thread members, never the archive).
//
//  Bounded by construction: thread membership comes from the persisted
//  thread_keys table (no runtime archive grouping), hydration is capped at
//  `maxThreadEmails`, and a larger thread says so honestly.
//

import SwiftUI

struct ThreadStoryView: View {
    let email: MBOXParser.RawEmail
    /// Optional: navigate the main detail pane to a timeline entry.
    var onSelectEmail: ((UUID) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var members: [MBOXParser.RawEmail] = []
    @State private var isLoading = true
    @State private var truncated = false
    @State private var narrative: String = ""
    @State private var isNarrating = false
    @State private var narrativeTask: Task<Void, Never>?

    static let maxThreadEmails = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                Spacer()
                HStack { Spacer(); ProgressView("Reconstructing thread…"); Spacer() }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        summaryStrip
                        if truncated {
                            Label("Large thread — showing the first \(Self.maxThreadEmails) messages chronologically.",
                                  systemImage: "info.circle")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }
                        narrativeSection
                        timeline
                    }
                    .padding(Spacing.medium)
                }
            }
        }
        .toolWindowFrame()
        .task { await load() }
        .onDisappear { stopNarrative() }
        .accessibilityIdentifier("threadStory")
    }

    private var header: some View {
        HStack {
            Label("Thread Story", systemImage: "text.bubble")
                .font(Typography.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help("Close thread story")
            .accessibilityLabel("Close thread story")
        }
        .padding(Spacing.medium)
    }

    private var summaryStrip: some View {
        let participants = Set(members.compactMap { $0.headers["From"] }).count
        let dates = members.compactMap { MBOXParser.parseDate($0.headers["Date"]) }
        let span: String
        if let first = dates.min(), let last = dates.max() {
            let fmt = DateFormatter(); fmt.dateStyle = .medium
            span = first == last ? fmt.string(from: first) : "\(fmt.string(from: first)) – \(fmt.string(from: last))"
        } else { span = "—" }
        return HStack(spacing: Spacing.medium) {
            statChip(icon: "envelope", text: "\(members.count) message\(members.count == 1 ? "" : "s")")
            statChip(icon: "person.2", text: "\(participants) participant\(participants == 1 ? "" : "s")")
            statChip(icon: "calendar", text: span)
        }
    }

    private func statChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(Typography.caption1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(AppColors.secondary.opacity(0.08))
            .cornerRadius(CornerRadius.small)
    }

    @ViewBuilder
    private var narrativeSection: some View {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), FoundationModelEngine.isAvailable {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                HStack {
                    Label("AI Narrative", systemImage: "sparkles")
                        .font(Typography.subheadline).fontWeight(.semibold)
                    Spacer()
                    if isNarrating {
                        Button {
                            stopNarrative()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .help("Stop generating — keeps what's written so far")
                    } else if narrative.isEmpty {
                        Button("Generate") { generateNarrative() }
                            .help("Summarize this thread's story — grounded in exactly the messages below")
                    } else {
                        Button("Regenerate") { generateNarrative() }
                            .help("Generate the narrative again")
                    }
                }
                if isNarrating && narrative.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if !narrative.isEmpty {
                    Text(markdownNarrative)
                        .font(Typography.callout)
                        .textSelection(.enabled)
                        .padding(Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.purple.opacity(0.06))
                        .cornerRadius(CornerRadius.medium)
                    Text("Grounded in the \(members.count) messages below — verify against the timeline.")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }
        }
        #endif
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                Button {
                    onSelectEmail?(member.id)
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: Spacing.small) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(member.id == email.id ? AppColors.primary : AppColors.secondary.opacity(0.4))
                                .frame(width: 9, height: 9)
                            if index < members.count - 1 {
                                Rectangle()
                                    .fill(AppColors.secondary.opacity(0.2))
                                    .frame(width: 1.5)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(member.headers["From"] ?? "Unknown sender")
                                    .font(Typography.caption1).fontWeight(.semibold)
                                    .lineLimit(1)
                                Spacer()
                                Text(member.headers["Date"] ?? "")
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.secondary)
                                    .lineLimit(1)
                            }
                            Text(member.headers["Subject"] ?? "(No Subject)")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                                .lineLimit(1)
                            Text(String(member.plainBody.prefix(180)).replacingOccurrences(of: "\n", with: " "))
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary.opacity(0.8))
                                .lineLimit(2)
                        }
                        .padding(.bottom, Spacing.medium)
                    }
                }
                .buttonStyle(.plain)
                .help("Open this message")
                .accessibilityLabel("Open message from \(member.headers["From"] ?? "unknown")")
            }
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            var ids: [UUID]
            if let key = try await ArchiveThreadService.shared.threadKey(for: email.id) {
                ids = try await ArchiveThreadService.shared.emailIDs(
                    inThread: key, limit: Self.maxThreadEmails + 1, offset: 0)
            } else {
                ids = [email.id]
            }
            if ids.count > Self.maxThreadEmails {
                truncated = true
                ids = Array(ids.prefix(Self.maxThreadEmails))
            }
            let hydrated = try await ArchiveDataService.shared.fullEmails(ids: ids)
            // Chronological story order (the service returns newest-first).
            members = hydrated.sorted {
                (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast)
                    < (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
            }
            if members.isEmpty { members = [email] }
        } catch {
            members = [email]
        }
    }

    /// The model streams markdown — render it formatted, not as raw
    /// asterisks (falls back to plain text if parsing fails mid-stream).
    private var markdownNarrative: AttributedString {
        (try? AttributedString(
            markdown: narrative,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(narrative)
    }

    private func generateNarrative() {
        #if canImport(FoundationModels)
        guard #available(macOS 26, iOS 26, *) else { return }
        isNarrating = true
        narrative = ""
        let thread = members
        narrativeTask = Task {
            _ = try? await FoundationModelEngine.synthesizeThread(thread) { partial in
                guard !Task.isCancelled else { return }
                narrative = partial
            }
            if !Task.isCancelled { isNarrating = false }
        }
        #endif
    }

    /// Stop keeps the partial narrative — the user chose to interrupt, not
    /// to discard.
    private func stopNarrative() {
        narrativeTask?.cancel()
        narrativeTask = nil
        isNarrating = false
    }
}
