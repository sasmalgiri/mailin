@testable import ArchiveCore
//
//  ArchiveWorkingSetView.swift
//  maxmailin
//
//  Part G (v2-core-cutover): reusable bounded working-set host. Legacy feature
//  views that still take `[MBOXParser.RawEmail]` are fed a CAPPED hydration of
//  the CURRENT archive query, streamed from the bounded store — the
//  GeneralAnalysisView / AIAssistantView precedent — instead of receiving the
//  resident preview arrays as archive truth.
//
//  The host never holds more than `cap` emails; the stream is cancelled as
//  soon as the cap is reached. This is an explicit, structural bound — not a
//  compat accessor that fakes the whole corpus.
//

import SwiftUI

enum ArchiveWorkingSet {
    /// Default cap for a feature view's working set (2K–5K per the migration
    /// plan; 2K matches GeneralAnalysisView / AIAssistantView).
    static let defaultCap = 2_000
}

extension ArchiveDataService {
    /// Bounded most-recent working set for `query` (≤ `cap` full emails),
    /// streamed in keyset pages so peak residency stays one page + the cap.
    func workingSet(query: EmailQuery = .all,
                    cap: Int = ArchiveWorkingSet.defaultCap,
                    batchSize: Int = 200) async -> [MBOXParser.RawEmail] {
        var acc: [MBOXParser.RawEmail] = []
        let stream = streamFullEmails(query: query, batchSize: batchSize)
        do {
            for try await batch in stream {
                acc.append(contentsOf: batch)
                if acc.count >= cap { break }
            }
        } catch { /* best-effort working set; partial results are still bounded */ }
        return acc.count > cap ? Array(acc.prefix(cap)) : acc
    }
}

/// Hosts a legacy `[RawEmail]`-taking feature view over a bounded working set
/// it streams itself from the store for the given query.
struct ArchiveWorkingSetView<Content: View>: View {
    var query: EmailQuery = .all
    var cap: Int = ArchiveWorkingSet.defaultCap
    @ViewBuilder var content: ([MBOXParser.RawEmail]) -> Content

    @State private var workingSet: [MBOXParser.RawEmail] = []
    @State private var scopeTotal = 0
    @State private var isLoaded = false

    var body: some View {
        Group {
            if isLoaded {
                VStack(spacing: 0) {
                    // The tool only sees the newest `cap` emails. Say so, so
                    // "all emails", "no anomalies in the archive" and the like
                    // are never read as covering mail the tool never received.
                    if scopeTotal > workingSet.count {
                        WorkingSetLimitNotice(shown: workingSet.count, total: scopeTotal)
                    }
                    content(workingSet)
                }
            } else {
                VStack {
                    Spacer()
                    ProgressView("Loading emails…")
                        .font(Typography.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: query) {
            workingSet = await ArchiveDataService.shared.workingSet(query: query, cap: cap)
            scopeTotal = (try? await ArchiveDataService.shared.count(query: query)) ?? workingSet.count
            isLoaded = true
        }
    }
}

extension View {
    /// For tools that stream their own bounded working set: pins the
    /// limit notice above the tool when it holds fewer emails than its scope.
    func workingSetLimitNotice(shown: Int, total: Int) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if total > shown && shown > 0 {
                WorkingSetLimitNotice(shown: shown, total: total)
            }
        }
    }
}

/// Shown above a tool whose working set is smaller than its scope.
struct WorkingSetLimitNotice: View {
    let shown: Int
    let total: Int

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xSmall) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.orange)
            Text("This tool is working on the newest \(shown.formatted()) of the \(total.formatted()) emails in this scope. Older emails are not included in its results, holds or exports — narrow the scope (date range, sender, folder or search) to work on them.")
                .font(Typography.caption1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Spacing.xSmall)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}
