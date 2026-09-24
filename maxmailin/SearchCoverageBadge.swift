//
//  SearchCoverageBadge.swift
//  mailin
//
//  S0 remainder: tell the user when search does NOT cover everything.
//
//  The index has a per-message text budget (`FTSSearchIndex
//  .indexedTextBudgetBytes`, 4 MiB). Before S0 the limit was a silent
//  50,000-character truncation: a 20 MB message was searchable only in its
//  first fraction and nothing ever said so, which for a forensic tool is the
//  worst kind of limit — an absent search hit is indistinguishable from
//  "that phrase is not in the archive".
//
//  S0 made the budget measurable (`indexed_text_bytes` / `total_text_bytes`
//  per indexed message). This is the part that makes it VISIBLE at the moment
//  it matters: while the user is reading search results.
//
//  Deliberately cheap and independent: it reads the shard counter directly
//  through the nonisolated snapshot, owns its own refresh, and belongs to the
//  Archive page (Page 1) — no module gate, because search coverage is an
//  Archive fact and Page 1 must not depend on any optional page.
//

import SwiftUI
import os.log

private let coverageLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin",
                                 category: "SearchCoverage")

/// A one-line, dismissible note under the search field: "N messages are
/// indexed only in part". Renders nothing at all when coverage is complete,
/// which is the normal case — a badge that is always on teaches users to
/// ignore it.
struct SearchCoverageBadge: View {

    /// Shown only while a query is active: the caveat is about *these results*.
    let isQueryActive: Bool

    @State private var partialCount: Int?
    @State private var isDismissed = false
    @State private var showDetail = false

    var body: some View {
        Group {
            if isQueryActive, !isDismissed, let partialCount, partialCount > 0 {
                content(partialCount: partialCount)
            }
        }
        .task(id: isQueryActive) {
            guard isQueryActive else { return }
            await refresh()
        }
    }

    private func content(partialCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.orange)

            Text(label(partialCount: partialCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Why?") { showDetail = true }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tint)
                .accessibilityHint("Explains why some messages are only partly searchable")

            Spacer(minLength: 0)

            Button {
                isDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss search coverage note")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(partialCount: partialCount))
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            detail(partialCount: partialCount)
        }
    }

    private func label(partialCount: Int) -> String {
        let budget = ByteCountFormatter.string(
            fromByteCount: Int64(FTSSearchIndex.indexedTextBudgetBytes), countStyle: .file)
        return partialCount == 1
            ? "1 message is searchable only in its first \(budget)."
            : "\(partialCount) messages are searchable only in their first \(budget)."
    }

    private func accessibilityLabel(partialCount: Int) -> String {
        label(partialCount: partialCount)
            + " Results may be incomplete for those messages."
    }

    private func detail(partialCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search coverage")
                .font(.headline)

            Text(label(partialCount: partialCount))
                .font(.callout)

            Text("""
                Very large messages are indexed up to a fixed byte budget so one \
                message cannot consume the whole index. Text beyond the budget is \
                still STORED and still exports byte-for-byte — it is only the \
                full-text search that stops there.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("""
                What this means for a result set: a phrase that appears only in \
                the later part of one of these messages will not be found by \
                search. Open the message and use Find within it.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func refresh() async {
        let count: Int? = await Task.detached(priority: .utility) {
            do {
                return try FTSSearchIndex.partiallyIndexedCountSnapshot()
            } catch {
                // A missing or unopenable index is not something to shout
                // about in the search bar — it just means there is nothing
                // to warn about yet.
                coverageLog.debug("coverage snapshot unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
        await MainActor.run { partialCount = count }
    }
}

// A per-message coverage note ("this message is indexed up to N of M bytes")
// is deliberately NOT here. The only existing surfaces that could host it are
// the forensic detail block, which is Professional-owned — putting an Archive
// fact behind an optional page would break page independence (R1–R6) — and
// `RawSourceView`, which receives text rather than an email id and so cannot
// look coverage up. `FTSSearchIndex.coverage(for:)` and `TextCoverage.summary`
// already exist for whichever Archive-owned surface takes it on.
