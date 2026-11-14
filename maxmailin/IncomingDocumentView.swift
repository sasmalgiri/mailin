//
//  IncomingDocumentView.swift
//  maxmailin
//
//  3.1: what happens when a mailin file is opened from Finder, Files, Mail or
//  AirDrop.
//  • .mailinpack — the reviewer screen (any tier; nothing enters the archive).
//  • .mailinresponse — shows who answered and how many decisions, then merges
//    on request (Professional; codes already set are never replaced).
//  • .mailinscript — shows the code; added to Scripts only on request.
//

import SwiftUI
@testable import ArchiveCore

struct IncomingMailinDocument: Identifiable {
    static let extensions: Set<String> = [ReviewPackFormat.packExtension, ReviewPackFormat.responseExtension, ScriptFile.fileExtension]
    let id = UUID()
    let url: URL
}

struct IncomingDocumentView: View {
    let document: IncomingMailinDocument
    @Environment(ModuleRegistry.self) private var modules
    @Environment(\.dismiss) private var dismiss
    @State private var pack: OpenedReviewPack?
    @State private var response: (header: ReviewResponseHeader, decisions: Int)?
    @State private var script: MailinScript?
    @State private var status: String?
    @State private var working = false

    var body: some View {
        Group {
            if let pack {
                ReviewPackReviewerView(pack: pack)
            } else {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    if let response {
                        Text("Review response from \(response.header.reviewer)").font(.headline)
                        Text("\(response.decisions) decisions, made \(response.header.createdAt.formatted()).")
                        if modules.isEnabled(.professional) && TierAccess.allows(.sendReviewPack) {
                            Button(working ? String(localized: "Merging…") : String(localized: "Merge \(response.decisions) decisions into my archive")) {
                                Task { await merge() }
                            }
                            .disabled(working)
                            Text("Codes you have already set are never replaced; disagreements go to the conflict list.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Merging responses is part of Professional.").foregroundStyle(.secondary)
                        }
                    } else if let script {
                        Text(script.label).font(.headline)
                        Text(script.summary)
                        ScrollView { Text(script.source).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        if modules.isOn(.v31Scripts) && TierAccess.allows(.scripts) {
                            Button(String(localized: "Add to my scripts")) {
                                ScriptLibraryStore.shared.upsert(script)
                                status = String(localized: "Imported \(script.label). Read it before you run it.")
                            }
                        } else {
                            Text("mailin Scripts are part of Professional; turn them on in Settings ▸ Modules.").foregroundStyle(.secondary)
                        }
                    }
                    if let status { Text(status).textSelection(.enabled) }
                    Spacer()
                    Button(String(localized: "Close")) { dismiss() }
                }
                .padding()
            }
        }
        .task { open() }
    }

    private func open() {
        let url = document.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Work on a private copy, so the scope can end and the original is never written.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            switch url.pathExtension.lowercased() {
            case ReviewPackFormat.packExtension:
                guard modules.isOn(.v31ReviewPack) else {
                    status = String(localized: "Turn on Review Pack in Settings ▸ Modules to review this pack.")
                    return
                }
                pack = try OpenedReviewPack.open(copy)
            case ReviewPackFormat.responseExtension:
                var header: ReviewResponseHeader?
                _ = try SignedLineReader.verify(url: copy) { first in
                    let h = try SignedLineReader.decoder().decode(ReviewResponseHeader.self, from: first)
                    header = h
                    return h.reviewerKey
                }
                var lines = 0
                try SignedLineReader.forEachLine(url: copy) { _ in lines += 1 }
                if let header { response = (header, max(0, lines - 1)) }
                responseURL = copy
            case ScriptFile.fileExtension:
                script = try ScriptFile.importScript(try Data(contentsOf: copy))
            default:
                status = String(localized: "This is not a mailin Review Pack or response.")
            }
        } catch {
            status = error.localizedDescription
        }
    }

    @State private var responseURL: URL?

    private func merge() async {
        guard let responseURL else { return }
        if let why = OrgPolicy.denial(.review) { status = why; return }
        working = true
        defer { working = false }
        do {
            let r = try await ReviewResponseMerger.merge(url: responseURL)
            status = String(localized: "Merged \(r.reviewer)'s \(r.decisions) decisions: \(r.codesApplied) codes, \(r.tagsAdded) tags and \(r.notesAdded) notes applied; \(r.unchanged) unchanged; \(r.conflicts.count) conflicts; \(r.notInArchive) emails not in this archive.")
            response = nil
        } catch {
            status = error.localizedDescription
        }
    }
}
