@testable import ArchiveCore
//
//  ArchiveWideLists.swift
//  maxmailin
//
//  §3-A7 / §3-A8 (switch: `v3AnalysisQueries`). Lists that cover the whole
//  archive, page by page, with the exact total shown:
//   • every attachment (metadata from the database; a file is read only when
//     opened, from its own email);
//   • every distinct subject with its count (Re:/Fwd: folded), one tap away
//     from the emails that carry it.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ArchiveAttachmentIndexView: View {
    /// §3-M3: the list could not be read; the host falls back to its previous view.
    var onFailure: (Error) -> Void = { _ in }
    @State private var rows: [SQLiteEmailStore.AttachmentRow] = []
    @State private var totals: (count: Int, bytes: Int64) = (0, 0)
    @State private var search = ""
    @State private var loading = false
    @State private var exhausted = false
    @State private var note: String?
    #if os(iOS)
    @State private var previewURL: URL?
    #endif

    static let pageSize = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField(String(localized: "Search attachments"), text: $search)
                    .textFieldStyle(.roundedBorder)
                Text("\(rows.count.formatted()) of \(totals.count.formatted()) · \(ByteCountFormatter.string(fromByteCount: totals.bytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Spacing.small)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, Spacing.small) }
            List {
                ForEach(rows, id: \.rowID) { row in
                    Button { open(row) } label: {
                        HStack {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.filename.isEmpty ? String(localized: "(unnamed)") : row.filename).lineLimit(1)
                                Text("\(row.emailSubject) — \(row.emailDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(row.sizeBytes), countStyle: .file))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !exhausted {
                    Button(loading ? String(localized: "Loading…") : String(localized: "Load more")) {
                        Task { await loadMore() }
                    }
                    .disabled(loading)
                    .onAppear { Task { await loadMore() } }
                }
            }
            .accessibilityLabel(String(localized: "Attachments"))
        }
        .task(id: search) {
            rows = []
            exhausted = false
            do {
                totals = try await SQLiteEmailStore.shared.attachmentRowsTotals(nameContains: search)
            } catch is CancellationError {
                return
            } catch {
                onFailure(error)
                return
            }
            await loadMore()
        }
        #if os(iOS)
        .sheet(item: Binding(get: { previewURL.map { PreviewItem(url: $0) } }, set: { previewURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
        #endif
    }

    private struct PreviewItem: Identifiable { let url: URL; var id: URL { url } }

    private func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        defer { loading = false }
        let page: [SQLiteEmailStore.AttachmentRow]
        do {
            page = try await SQLiteEmailStore.shared.attachmentRowsPage(after: rows.last?.rowID, nameContains: search,
                                                                       limit: Self.pageSize)
        } catch is CancellationError {
            return
        } catch {
            exhausted = true
            onFailure(error)
            return
        }
        rows += page
        if page.count < Self.pageSize { exhausted = true }
    }

    /// Reads the one email, writes the attachment to a private temp file, opens it.
    private func open(_ row: SQLiteEmailStore.AttachmentRow) {
        Task { @MainActor in
            guard let email = try? await ArchiveDataService.shared.fullEmails(ids: [row.emailID]).first else {
                note = String(localized: "The email could not be read."); return
            }
            let candidates = email.attachments
            let attachment = candidates.indices.contains(row.position) && candidates[row.position].filename == row.filename
                ? candidates[row.position]
                : candidates.first(where: { $0.filename == row.filename })
            guard let attachment else { note = String(localized: "The attachment is not stored in this email."); return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mailin_preview/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = attachment.filename.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "..", with: "_")
            let url = dir.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
            if let b64 = attachment.base64, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                try? data.write(to: url, options: .atomic)   // lint:allow private temp preview copy; checked by fileExists below
            } else if let src = attachment.fileURL {
                try? FileManager.default.copyItem(at: src, to: url)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                note = String(localized: "The attachment's content was not kept at import."); return
            }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            previewURL = url
            #endif
        }
    }
}

struct ArchiveSubjectGroupsView: View {
    /// Called with the ids of the emails carrying the tapped subject.
    var onSelect: (Set<UUID>) -> Void
    /// §3-M3: the list could not be read; the host falls back to its previous view.
    var onFailure: (Error) -> Void = { _ in }

    @State private var rows: [(subject: String, count: Int)] = []
    @State private var distinct = 0
    /// The plan's reach when the rows were read (Free = newest 500), nil for the whole archive.
    @State private var scopeLimit: Int? = nil
    @State private var loading = false
    @State private var exhausted = false

    static let pageSize = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let scopeLimit {
                    Text("\(rows.count.formatted()) of \(distinct.formatted()) subjects — newest \(scopeLimit.formatted()) emails")
                } else {
                    Text("\(rows.count.formatted()) of \(distinct.formatted()) subjects — whole archive")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(Spacing.small)
            List {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Button {
                        Task { @MainActor in
                            var q = EmailQuery.all
                            q.subjectContains = row.subject
                            var ids = Set<UUID>()
                            do {
                                for try await page in ArchiveDataService.shared.streamSummaries(query: q, batchSize: 5_000) {
                                    ids.formUnion(page.map(\.id))
                                }
                            } catch {}
                            onSelect(ids)
                        }
                    } label: {
                        HStack {
                            Text(row.subject.isEmpty ? String(localized: "(No Subject)") : row.subject).lineLimit(1)
                            Spacer()
                            Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "\(row.subject.isEmpty ? String(localized: "(No Subject)") : row.subject), \(row.count) emails"))
                    }
                    .buttonStyle(.plain)
                }
                if !exhausted {
                    Button(loading ? String(localized: "Loading…") : String(localized: "Load more")) { Task { await loadMore() } }
                        .disabled(loading)
                        .onAppear { Task { await loadMore() } }
                }
            }
            .accessibilityLabel(String(localized: "Subjects"))
        }
        .task { if rows.isEmpty { await loadMore() } }
        // A purchase, expiry or restore changes what the plan reaches: read the groups again.
        .onReceive(NotificationCenter.default.publisher(for: .accessScopeChanged)) { _ in
            rows = []; distinct = 0; exhausted = false
            Task { await loadMore() }
        }
    }

    private func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        defer { loading = false }
        let page: (rows: [(subject: String, count: Int)], distinct: Int)
        do {
            let p = try await SQLiteEmailStore.shared.subjectGroups(query: ArchiveDataService.shared.scoped(.all),
                                                                   limit: Self.pageSize, offset: rows.count)
            page = (p.rows, p.distinct)
        } catch is CancellationError {
            return
        } catch {
            exhausted = true
            onFailure(error)
            return
        }
        distinct = page.distinct
        scopeLimit = ArchiveDataService.shared.accessLimit
        rows += page.rows
        if page.rows.count < Self.pageSize { exhausted = true }
    }
}
