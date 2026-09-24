//
//  GuidedImportSheet.swift
//  mailin
//
//  A3: show what is about to happen, before anything is written.
//
//  Everything on this sheet already existed as a decision the app made
//  silently: the classifier decided which parser to use, `StoragePlanner`
//  decided whether there was room, `SourceSizePolicy` decided whether to warn,
//  and `FTSSearchIndex` decided how much of each message to index. The user
//  learned about all of it afterwards, in a receipt, once the work was done.
//
//  That is the wrong order for the one irreversible-feeling step in the app.
//  This sheet moves those four answers in front of the decision:
//
//    what it IS       — detected format, with the evidence for the detection
//    what it COSTS    — measured store + index requirement against free space
//    what may be LOST — a documented format ceiling, or an index budget
//    what happens NEXT — engine, duplicate policy, whether originals are copied
//
//  Behind `Capability.guidedImport` (Preview, OFF by default). With it off,
//  selecting files starts the import immediately, as in 2.x — the preflight
//  and the receipt still run, so nothing is skipped, it is just not shown
//  first.
//

import SwiftUI

/// One source's pre-import analysis. Pure data, computed off the main actor.
struct ImportPlanItem: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let sizeBytes: Int64
    let classification: SourceClassification

    var name: String { url.lastPathComponent }
    var isSupported: Bool { classification.isSupported }
}

struct ImportPlan: Sendable {
    var items: [ImportPlanItem] = []
    var storagePlan: StoragePlan?
    /// Per-message index budget, so the sheet can say what "searchable" means
    /// for a large message rather than leaving it to be discovered.
    var indexBudgetBytes: Int = FTSSearchIndex.indexedTextBudgetBytes

    var supported: [ImportPlanItem] { items.filter(\.isSupported) }
    var unsupported: [ImportPlanItem] { items.filter { !$0.isSupported } }
    var totalBytes: Int64 { supported.reduce(0) { $0 + $1.sizeBytes } }

    /// True when there is nothing worth starting.
    var isEmpty: Bool { supported.isEmpty }

    static func build(urls: [URL], destination: URL, copiesOriginals: Bool) -> ImportPlan {
        var plan = ImportPlan()
        for url in urls {
            let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            plan.items.append(ImportPlanItem(
                url: url,
                sizeBytes: size,
                classification: SourceFormatClassifier.classify(url: url)))
        }
        // Only supported sources count toward the requirement: refusing an
        // import because of bytes we are not going to read would be wrong.
        plan.storagePlan = StoragePlanner.plan(
            sources: plan.supported.map(\.url),
            destination: destination,
            copyOriginals: copiesOriginals)
        return plan
    }
}

struct GuidedImportSheet: View {
    let urls: [URL]
    let dedupPolicy: DedupPolicy
    let copiesOriginals: Bool
    let onStart: ([URL]) -> Void
    let onCancel: () -> Void

    @Environment(ModuleRegistry.self) private var modules
    @State private var plan: ImportPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let plan {
                        whatItIs(plan)
                        whatItCosts(plan)
                        whatMayBeLost(plan)
                        whatHappensNext(plan)
                    } else {
                        Text("Examining the files…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 460)
        .task { await build() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(urls.count == 1 ? "Import 1 file" : "Import \(urls.count) files")
                .font(.title3.weight(.semibold))
            Text("Nothing is written until you start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func whatItIs(_ plan: ImportPlan) -> some View {
        section("What these files are", systemImage: "doc.text.magnifyingglass") {
            ForEach(plan.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: item.isSupported
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(item.isSupported ? .green : .red)
                            .font(.caption)
                        Text(item.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // The classifier's own evidence sentence: "detected X —
                    // PST/OST signature !BDN at offset 0". A name/content
                    // mismatch shows here, which is how a PST called .mbox
                    // becomes visible BEFORE it is parsed.
                    Text(item.classification.summary)
                        .font(.caption2)
                        .foregroundStyle(item.classification.nameContentMismatch
                                         ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let advice = item.classification.format.advice, !item.isSupported {
                        Text(advice)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func whatItCosts(_ plan: ImportPlan) -> some View {
        if let storage = plan.storagePlan {
            section("Space", systemImage: "internaldrive") {
                Text(storage.summary)
                    .font(.caption)
                    .foregroundStyle(storage.canProceed ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text("""
                    Estimated from measurements, not guesses: the archive holds about 1.3× the \
                    source bytes and the search index about 0.2×.
                    """)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func whatMayBeLost(_ plan: ImportPlan) -> some View {
        let warnings = plan.items.compactMap(\.classification.warning)
        section("What to expect", systemImage: "exclamationmark.triangle") {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("""
                Messages larger than \(ByteCountFormatter.string(fromByteCount: Int64(plan.indexBudgetBytes), countStyle: .file)) \
                of text are stored and exported in full, but full-text search covers only the \
                first part of them. The import receipt says exactly how many were affected.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !modules.isOn(.offsetParser) {
                Text("""
                    A single message over 100 MB will be reported as damaged and skipped. \
                    Switching on “Offset parser” in Settings ▸ Features archives those \
                    messages instead.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func whatHappensNext(_ plan: ImportPlan) -> some View {
        section("How it will run", systemImage: "gearshape") {
            row("Engine", modules.isOn(.offsetParser)
                ? "Offset parser (no message size limit)"
                : "Streaming parser")
            row("Duplicates", dedupPolicy == .preserveAll
                ? "Keep every copy"
                : "Skip messages already in the archive")
            row("Originals", copiesOriginals
                ? "Copied into the archive"
                : "Referenced where they are")
            row("Large bodies", modules.isOn(.blobTier)
                ? "Stored beside the database above 8 MB"
                : "Stored inside the database")
            row("Receipt", "Written for every source, with a Complete / Partial / Failed verdict")
        }
    }

    private var footer: some View {
        HStack {
            if let plan, !plan.unsupported.isEmpty {
                Text("\(plan.unsupported.count) file\(plan.unsupported.count == 1 ? "" : "s") will be skipped.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Start import") {
                onStart(plan?.supported.map(\.url) ?? urls)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            // Disabled when there is nothing supported to import, or when the
            // preflight says it cannot finish — the coordinator would refuse
            // anyway, and offering a button that throws is worse than a
            // disabled one with the shortfall stated above it.
            .disabled(plan == nil || plan?.isEmpty == true
                      || plan?.storagePlan?.canProceed == false)
        }
        .padding(16)
    }

    // MARK: Plumbing

    private func build() async {
        let destination = SQLiteEmailStore.productionDirectory
        let sources = urls
        let copies = copiesOriginals
        let built = await Task.detached(priority: .userInitiated) {
            ImportPlan.build(urls: sources, destination: destination, copiesOriginals: copies)
        }.value
        plan = built
    }

    private func section<Content: View>(_ title: String,
                                        systemImage: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
