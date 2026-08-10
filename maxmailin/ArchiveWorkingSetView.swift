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
    @State private var isLoaded = false

    var body: some View {
        Group {
            if isLoaded {
                content(workingSet)
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
            isLoaded = true
        }
    }
}
