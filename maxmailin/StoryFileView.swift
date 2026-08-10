//
//  StoryFileView.swift
//  maxmailin
//
//  Journalist's story file: preview + export of every annotated email as
//  a cited finding (StoryFileBuilder). Copy as Markdown or save to disk.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct StoryFileView: View {
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var forensicManager = ForensicManager.shared
    @State private var title = ""
    @State private var markdown = ""
    @State private var currentFindings: [StoryFileBuilder.Finding] = []
    @State private var findingCount = 0
    @State private var isLoading = true
    @State private var copied = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    Label("Story File", systemImage: "text.book.closed")
                        .font(Typography.title2)
                    Text(isLoading
                         ? "Collecting findings…"
                         : "\(findingCount) finding(s) — every annotation you made, cited to its source email")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                Spacer()
                HelpDot(text: "Annotate emails while you research; each annotation becomes a numbered finding here with its source cited (sender, date, subject, Message-ID). This is the document that answers your editor's 'how do you know this?' — copy it as Markdown or save it beside your draft.")
                Button {
                    PlatformClipboard.copyString(markdown)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Markdown", systemImage: "doc.on.doc")
                }
                .disabled(isLoading)
                .help("Copy the whole story file as Markdown")
                #if os(macOS)
                Button {
                    saveMarkdown()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .disabled(isLoading)
                .help("Save the story file as a .md document")
                #endif
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close story file")
            }
            .padding(Spacing.medium)

            HStack(spacing: Spacing.xSmall) {
                Text("Title")
                    .font(Typography.caption1)
                TextField("Working title for the story", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await rebuild() } }
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.bottom, Spacing.xSmall)
            Divider()

            if isLoading {
                Spacer()
                HStack { Spacer(); ProgressView(); Spacer() }
                Spacer()
            } else {
                ScrollView {
                    Text(markdown)
                        .font(Typography.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.medium)
                }
            }
        }
        .toolWindowFrame()
        .task { await rebuild() }
        .alert("Save Failed", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "") }
    }

    @MainActor
    private func rebuild() async {
        let annotations = forensicManager.annotations
        let ids = Array(annotations.keys)
        let emails = (try? await ArchiveDataService.shared.fullEmails(ids: ids)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
        let findings: [StoryFileBuilder.Finding] = annotations.compactMap { id, note in
            guard let email = byID[id] else { return nil }
            let tag = forensicManager.tagForEmail(id)
            return StoryFileBuilder.Finding(
                claim: note.text,
                claimDate: note.timestamp,
                subject: email.headers["Subject"] ?? "(No Subject)",
                from: email.headers["From"] ?? "?",
                sentDate: email.headers["Date"] ?? "undated",
                messageID: email.headers["Message-ID"],
                evidenceTag: tag == .none ? nil : tag.rawValue)
        }
        currentFindings = findings
        findingCount = findings.count
        markdown = StoryFileBuilder.markdown(
            title: title, author: forensicManager.examinerName, findings: findings)
        isLoading = false
    }

    #if os(macOS)
    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (title.isEmpty ? "story_file" : title.replacingOccurrences(of: " ", with: "_")) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let savedTitle = title
        Task { @MainActor in
            let number = await DocumentRegistry.post(
                .storyVersion, summary: "Story file saved: \(savedTitle.isEmpty ? "Story File" : savedTitle)",
                refs: url.lastPathComponent)
            let versioned = StoryFileBuilder.markdown(
                title: savedTitle, author: forensicManager.examinerName,
                findings: currentFindings, documentNumber: number)
            do { try versioned.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = error.localizedDescription }
        }
    }
    #endif
}
