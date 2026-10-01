@testable import ArchiveCore
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

/// What the user decided on the sheet. Everything the import needs beyond the
/// files themselves.
struct ImportChoices: Sendable {
    var urls: [URL]
    var dedupPolicy: DedupPolicy
    var copiesOriginals: Bool
    /// Run the attachment-content indexer after the import (`in:attachments`
    /// searches file contents). Stored under `indexAttachmentTextKey` so the
    /// launch-time kick honours the last choice.
    var indexAttachmentText: Bool

    static let indexAttachmentTextKey = "indexAttachmentTextAfterImport"

    static func indexAttachmentTextDefault(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: indexAttachmentTextKey) == nil ? true : defaults.bool(forKey: indexAttachmentTextKey)
    }
}

struct GuidedImportSheet: View {
    let urls: [URL]
    let dedupPolicy: DedupPolicy
    let copiesOriginals: Bool
    let onStart: (ImportChoices) -> Void
    let onCancel: () -> Void

    @Environment(ModuleRegistry.self) private var modules
    @State private var plan: ImportPlan?
    // A3: the choices the plan asks for, made on the sheet rather than
    // inherited silently from Settings.
    @State private var chosenDedup: DedupPolicy = .messageID
    /// Always false in 3.0 (F03): nothing copies originals yet, and the space
    /// estimate must not claim otherwise. The stored flag stays so 3.1's real
    /// copy (I-1) has its plumbing.
    @State private var chosenCopiesOriginals = false
    @State private var chosenIndexAttachmentText = ImportChoices.indexAttachmentTextDefault()
    @State private var didSeedChoices = false
    /// Free input allowance: what the archive already holds (from the store)
    /// and what these files add, measured on disk including folder contents.
    @State private var ingestedBytes: Int?
    @State private var requestedBytes: Int?

    /// The tier's allowance, read from the app's one store manager; nil when
    /// the tier has no limit (or when no manager exists, as in previews).
    private var inputByteLimit: Int? { StoreManager.live?.inputByteLimit }

    private var allowanceDenial: ImportAllowance.Denial? {
        guard let inputByteLimit, let ingestedBytes, let requestedBytes else { return nil }
        return ImportAllowance.evaluate(requestedBytes: requestedBytes, ingestedBytes: ingestedBytes, limitBytes: inputByteLimit).denial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let plan {
                        whatItIs(plan)
                        allowance
                        choices
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
        .onAppear {
            guard !didSeedChoices else { return }
            chosenDedup = dedupPolicy
            chosenCopiesOriginals = false   // F03: no copy exists in 3.0, whatever the caller seeded
            didSeedChoices = true
        }
        // The space requirement depends on copy-vs-reference, so the plan is
        // rebuilt when that choice changes.
        .task(id: chosenCopiesOriginals) { await build() }
    }

    // MARK: Sections

    /// A3: duplicate policy, originals, indexing — chosen here, before Start.
    private var choices: some View {
        section("Choices", systemImage: "slider.horizontal.3") {
            Picker("Duplicates", selection: $chosenDedup) {
                Text("Skip messages already in the archive").tag(DedupPolicy.messageID)
                Text("Skip duplicates, including re-encoded copies").tag(DedupPolicy.messageIDOrCanonicalFingerprint)
                Text("Keep every copy").tag(DedupPolicy.preserveAll)
            }
            .help("Skip compares Message-IDs against the archive; Keep every copy imports each occurrence, which is what a forensic intake usually wants")
            .accessibilityIdentifier("import.sheet.duplicates")
            // Audit F03 (2026-09-28): the "Copy into the archive" choice was
            // offered but nothing copied. Until 3.1 implements a real copy,
            // the sheet states what actually happens to the originals.
            LabeledContent("Originals") {
                Text("""
                    Messages up to \(ByteCountFormatter.string(fromByteCount: OffsetImportEngine().fullParseCeilingBytes, countStyle: .file)) \
                    are stored inside the archive. Larger messages are read from the original file, \
                    which must stay where it is.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("import.sheet.originals")
            Toggle("Index attachment contents after import", isOn: $chosenIndexAttachmentText)
                .help("Extracts text from attachments in the background so in:attachments finds words inside PDFs and documents; off saves time and disk")
                .accessibilityIdentifier("import.sheet.attachmentText")
        }
        .pickerStyle(.menu)
        .controlSize(.small)
    }

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

    /// Free plan only: the input allowance, stated before the button, with
    /// the figures that decide it and the way to lift it.
    @ViewBuilder
    private var allowance: some View {
        if let limit = inputByteLimit {
            let f = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
            section("Free plan input allowance", systemImage: "lock") {
                row("Allowance", "\(f(limit)) of input in total")
                row("Already imported", ingestedBytes.map(f) ?? "Measuring…")
                row("This import adds", requestedBytes.map(f) ?? "Measuring…")
                if let ingestedBytes, let requestedBytes {
                    let after = ingestedBytes + requestedBytes
                    row("After this import", after <= limit ? "\(f(after)) (\(f(limit - after)) left)" : "\(f(after)) — over the allowance")
                }
                if let denial = allowanceDenial {
                    Text(denial.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        StoreManager.live?.requestPurchase(.personal, feature: "Import more than 100 MB", reason: denial.message)
                    } label: {
                        Label("Unlock with Personal…", systemImage: "lock.open.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("import.allowance.unlock")
                } else {
                    Text("Personal and Professional have no input limit.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("import.allowance")
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
            row("Duplicates", chosenDedup == .preserveAll
                ? "Keep every copy"
                : "Skip messages already in the archive")
            row("Originals", chosenCopiesOriginals
                ? "Copied into the archive"
                : "Referenced where they are")
            row("Attachments", chosenIndexAttachmentText
                ? "Contents indexed in the background after import"
                : "Stored and exported; contents not indexed")
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
                onStart(ImportChoices(urls: plan?.supported.map(\.url) ?? urls,
                                      dedupPolicy: chosenDedup,
                                      copiesOriginals: chosenCopiesOriginals,
                                      indexAttachmentText: chosenIndexAttachmentText))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            // Disabled when there is nothing supported to import, or when the
            // preflight says it cannot finish — the coordinator would refuse
            // anyway, and offering a button that throws is worse than a
            // disabled one with the shortfall stated above it.
            // Also disabled while the Free allowance is still being measured
            // or is exceeded: the funnel would refuse anyway, and the reason
            // is stated above the button.
            .disabled(plan == nil || plan?.isEmpty == true
                      || plan?.storagePlan?.canProceed == false
                      || (inputByteLimit != nil && (ingestedBytes == nil || requestedBytes == nil))
                      || allowanceDenial != nil)
        }
        .padding(16)
    }

    // MARK: Plumbing

    private func build() async {
        let destination = SQLiteEmailStore.productionDirectory
        let sources = urls
        let copies = chosenCopiesOriginals
        let built = await Task.detached(priority: .userInitiated) {
            ImportPlan.build(urls: sources, destination: destination, copiesOriginals: copies)
        }.value
        plan = built
        if inputByteLimit != nil {
            let supported = built.supported.map(\.url)
            requestedBytes = await Task.detached(priority: .userInitiated) {
                ImportAllowance.totalBytes(of: supported)
            }.value
            ingestedBytes = await ImportAllowance.ingestedBytes()
        }
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
