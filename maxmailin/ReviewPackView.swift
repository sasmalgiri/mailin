//
//  ReviewPackView.swift
//  maxmailin
//
//  3.1 T0 screens: the examiner builds a Review Pack and merges responses;
//  a reviewer opens a pack, codes it and saves a signed response.
//

import SwiftUI
import UniformTypeIdentifiers
@testable import ArchiveCore

struct ReviewPackView: View {
    @Environment(ModuleRegistry.self) private var modules
    @EnvironmentObject private var storeManager: StoreManager
    @State private var search = ""
    @State private var title = ""
    @State private var instructions = ""
    @State private var scopeCount: Int?
    @State private var isBuilding = false
    @State private var buildProgress: Double = 0
    @State private var status: String?
    @State private var showMergePicker = false
    @State private var showPackPicker = false
    @State private var conflicts: [ReviewMergeConflict] = []
    @State private var opened: OpenedReviewPack?

    var body: some View {
        Form {
            if !(modules.isEnabled(.professional) && storeManager.effectiveTier >= TierAccess.Feature.sendReviewPack.tier) {
                Section {
                    Text("Sending packs and merging responses are part of Professional. Reviewing a pack you received needs no purchase.")
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Unlock Professional")) {
                        storeManager.requestPurchase(.professional, feature: TierAccess.Feature.sendReviewPack.name, target: .settings)
                    }
                }
            } else {
            Section {
                TextField(String(localized: "Search (empty = whole archive)"), text: $search)
                    .onSubmit { Task { await countScope() } }
                TextField(String(localized: "Pack title"), text: $title)
                TextField(String(localized: "Instructions for the reviewer"), text: $instructions, axis: .vertical)
                if let scopeCount {
                    Text("\(scopeCount) emails will go into the pack.").font(.callout)
                }
                if isBuilding {
                    ProgressView(value: buildProgress)
                } else {
                    Button {
                        Task { await build() }
                    } label: {
                        Label("Create Review Pack…", systemImage: "shippingbox")
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button {
                    showMergePicker = true
                } label: {
                    Label("Merge a reviewer's response…", systemImage: "arrow.triangle.merge")
                }
            } header: {
                Text("Send for review")
            } footer: {
                Text("The pack holds the emails' text and attachment names, signed by this device. The reviewer opens it in any copy of mailin; nothing is added to their archive. Their response is merged here: codes you have already set are never replaced — disagreements go to the conflict list.")
            }

            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts) { c in
                        VStack(alignment: .leading) {
                            Text("Email \(c.emailID.uuidString.prefix(8)): yours “\(c.existing)”, \(c.reviewer) “\(c.proposed)”")
                            Text(c.decidedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Conflicts (\(conflicts.count))")
                }
            }
            }

            Section {
                Button {
                    showPackPicker = true
                } label: {
                    Label("Open a Review Pack…", systemImage: "tray.and.arrow.down")
                }
            } header: {
                Text("Review a pack you received")
            }

            if let status {
                Section { Text(status).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Review Pack"))
        .task {
            await countScope()
            conflicts = ReviewMergeLog.openConflicts()
        }
        .fileImporter(isPresented: $showMergePicker, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            Task { await merge(url) }
        }
        .fileImporter(isPresented: $showPackPicker, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            openPack(url)
        }
        .sheet(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let opened {
                ReviewPackReviewerView(pack: opened)
                    .frame(minWidth: 640, minHeight: 480)
            }
        }
    }

    private var scope: ArchiveScope {
        ArchiveScope(query: ArchiveQueryCompiler.compile(search), total: scopeCount, loaded: nil)
    }

    private func countScope() async {
        scopeCount = try? await ArchiveDataService.shared.count(query: scope.query)
    }

    private func build() async {
        if let why = OrgPolicy.denial(.export) { status = why; return }
        await countScope()
        let name = title.trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(ReviewPackFormat.packExtension)")
        isBuilding = true
        defer { isBuilding = false }
        do {
            let entry = try await ReviewPackBuilder.build(
                scope: scope, title: name, codes: ReviewPackBuilder.defaultCodes,
                instructions: instructions, to: url) { done, total in
                    buildProgress = total > 0 ? Double(done) / Double(total) : 1
                }
            guard let data = try? Data(contentsOf: url) else {
                status = String(localized: "The pack was written but could not be read back.")
                return
            }
            let outcome = PlatformExport.save(data: data, suggestedName: url.lastPathComponent)
            status = outcome.message(String(localized: "Review Pack (\(entry.emailCount) emails)"))
        } catch {
            status = error.localizedDescription
        }
    }

    private func merge(_ url: URL) async {
        if let why = OrgPolicy.denial(.review) { status = why; return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let r = try await ReviewResponseMerger.merge(url: url)
            status = String(localized: "Merged \(r.reviewer)'s \(r.decisions) decisions: \(r.codesApplied) codes, \(r.tagsAdded) tags and \(r.notesAdded) notes applied; \(r.unchanged) unchanged; \(r.conflicts.count) conflicts; \(r.notInArchive) emails not in this archive.")
            conflicts = ReviewMergeLog.openConflicts()
        } catch {
            status = error.localizedDescription
        }
    }

    private func openPack(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Work on a private copy so the security scope can end.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ReviewPackFormat.packExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            opened = try OpenedReviewPack.open(copy)
        } catch {
            status = error.localizedDescription
        }
    }
}

/// The reviewer's screen: list, reading pane, code buttons, tags, note.
struct ReviewPackReviewerView: View {
    let pack: OpenedReviewPack
    @Environment(\.dismiss) private var dismiss
    @AppStorage("forensicExaminerName") private var reviewerName = ""
    @State private var selection: Int? = 0
    @State private var current: ReviewPackEmail?
    @State private var decisions: [UUID: ReviewDecision] = [:]
    @State private var tagText = ""
    @State private var noteText = ""
    @State private var status: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(pack.index.indices, id: \.self) { i in
                    let e = pack.index[i]
                    VStack(alignment: .leading) {
                        Text(e.subject.isEmpty ? String(localized: "(no subject)") : e.subject).lineLimit(1)
                        HStack {
                            Text(e.from).font(.caption).lineLimit(1)
                            Spacer()
                            if let code = decisions[e.id]?.code { Text(code).font(.caption).foregroundStyle(.tint) }
                        }
                    }
                    .tag(i)
                }
            }
            .navigationTitle(pack.header.title)
        } detail: {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("\(decisions.count) of \(pack.index.count) coded").font(.caption).foregroundStyle(.secondary)
                if !pack.header.instructions.isEmpty {
                    Text(pack.header.instructions).font(.callout)
                }
                if let current {
                    Text(current.subject).font(.headline)
                    Text("From \(current.from) · \(current.date)").font(.caption)
                    if !current.attachments.isEmpty {
                        Text("Attachments: \(current.attachments.joined(separator: ", "))").font(.caption)
                    }
                    ScrollView { Text(current.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        ForEach(pack.header.codes, id: \.self) { code in
                            Button(code) { decide(code: code) }
                                .buttonStyle(.bordered)
                                .tint(decisions[current.id]?.code == code ? .accentColor : .secondary)
                        }
                    }
                    HStack {
                        TextField(String(localized: "Tags, comma-separated"), text: $tagText)
                        TextField(String(localized: "Note"), text: $noteText)
                        Button("Save") { decide(code: decisions[current.id]?.code) }
                    }
                }
                HStack {
                    TextField(String(localized: "Your name"), text: $reviewerName)
                    Button {
                        saveResponse()
                    } label: {
                        Label("Save signed response…", systemImage: "signature")
                    }
                    .disabled(decisions.isEmpty || reviewerName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Close") { dismiss() }
                }
                if let status { Text(status).font(.callout) }
            }
            .padding()
        }
        .onChange(of: selection, initial: true) { _, new in load(new) }
    }

    private func load(_ i: Int?) {
        guard let i, pack.index.indices.contains(i) else { current = nil; return }
        current = try? pack.email(at: i)
        let d = current.flatMap { decisions[$0.id] }
        tagText = d?.tags.joined(separator: ", ") ?? ""
        noteText = d?.note ?? ""
    }

    private func decide(code: String?) {
        guard let current else { return }
        let tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        decisions[current.id] = ReviewDecision(emailID: current.id, code: code, tags: tags,
                                               note: noteText.isEmpty ? nil : noteText, decidedAt: Date())
        // Move to the next uncoded email.
        if let i = selection, let next = pack.index.indices.first(where: { $0 > i && decisions[pack.index[$0].id] == nil }) {
            selection = next
        }
    }

    private func saveResponse() {
        let name = "\(pack.header.title) — \(reviewerName).\(ReviewPackFormat.responseExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try pack.writeResponse(decisions, reviewer: reviewerName, to: url)
            let outcome = PlatformExport.save(data: try Data(contentsOf: url), suggestedName: name)
            status = outcome.message(String(localized: "Response (\(decisions.count) of \(pack.index.count) emails)"))
        } catch {
            status = error.localizedDescription
        }
    }
}
