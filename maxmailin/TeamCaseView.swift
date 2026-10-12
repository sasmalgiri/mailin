//
//  TeamCaseView.swift
//  maxmailin
//
//  3.1/3.2 T1–T13 screen: create or open a shared case folder, see the team
//  dashboard (batches, throughput, conflicts, QC), review a checked-out batch,
//  resolve conflicts (lead), export the merged audit trail and apply the
//  resolved case to the archive (lead). Shown only while Capability.v31TeamCase is on.
//

import SwiftUI
import UniformTypeIdentifiers
@testable import ArchiveCore

struct TeamCaseView: View {
    @AppStorage("forensicExaminerName") private var myName = ""
    @State private var teamCase: TeamCase?
    @State private var state = TeamCaseState()
    @State private var status: String?
    // Create
    @State private var title = ""
    @State private var search = ""
    @State private var batchSize = 100
    @State private var qcPercent = 10
    @State private var showCreatePicker = false
    @State private var showOpenPicker = false
    @State private var creating = false
    @State private var progress: Double = 0
    // Review
    @State private var activeBatch: Int?

    var body: some View {
        Form {
            if let c = teamCase {
                dashboard(c)
            } else {
                Section {
                    TextField(String(localized: "Your name (shown to the team)"), text: $myName)
                    Button {
                        showOpenPicker = true
                    } label: { Label("Open a case folder…", systemImage: "folder") }
                    .disabled(myName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("Join a case") }
                Section {
                    TextField(String(localized: "Case title"), text: $title)
                    TextField(String(localized: "Search (empty = whole archive)"), text: $search)
                    Stepper(String(localized: "Batch size: \(batchSize)"), value: $batchSize, in: 10...1_000, step: 10)
                    Stepper(String(localized: "Second-level QC: \(qcPercent) %"), value: $qcPercent, in: 0...100, step: 5)
                    if creating { ProgressView(value: progress) }
                    Button {
                        showCreatePicker = true
                    } label: { Label("Create case on a shared folder…", systemImage: "folder.badge.plus") }
                    .disabled(title.isEmpty || myName.isEmpty || creating)
                } header: { Text("Start a case (lead)") } footer: {
                    Text("The case folder can live on a file server, NAS or external drive. Everyone works offline; each person's work is a signed log in the folder, and every copy of mailin reading the folder shows the same result.")
                }
            }
            if let status { Section { Text(status).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Team case"))
        .fileImporter(isPresented: $showCreatePicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let parent) = result else { return }
            Task { await create(in: parent) }
        }
        .fileImporter(isPresented: $showOpenPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            open(url)
        }
        .sheet(item: Binding(get: { activeBatch.map(BatchRef.init) }, set: { activeBatch = $0?.id })) { ref in
            if let c = teamCase {
                TeamBatchReviewView(teamCase: c, batch: ref.id, state: $state)
                    .frame(minWidth: 680, minHeight: 500)
            }
        }
    }

    struct BatchRef: Identifiable { var id: Int }

    @ViewBuilder
    private func dashboard(_ c: TeamCase) -> some View {
        let isLead = c.myKey == c.manifest.leadKey
        let coded = state.emails.values.filter { !$0.codes.isEmpty }.count
        Section {
            LabeledContent(String(localized: "Emails"), value: "\(c.evidence.index.count)")
            LabeledContent(String(localized: "Coded"), value: "\(coded) of \(c.evidence.index.count)")
            LabeledContent(String(localized: "Open conflicts"), value: "\(state.conflicts.count)")
            LabeledContent(String(localized: "Team"), value: state.members.values.map(\.name).sorted().joined(separator: ", "))
            ForEach(state.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(String(localized: "Refresh")) { reload() }
                Button(String(localized: "Close case")) { teamCase = nil }
            }
        } header: { Text(c.manifest.title + (isLead ? String(localized: " — you lead") : "")) }

        Section {
            ForEach(c.manifest.batches.indices, id: \.self) { b in
                HStack {
                    Text("Batch \(b + 1) · \(c.manifest.batches[b].count) emails")
                    Spacer()
                    if state.batchDone.contains(b) {
                        Text("Completed").foregroundStyle(.secondary)
                    } else if let l = c.lease(b) {
                        Text(l.holder == c.myKey ? String(localized: "Yours") : String(localized: "\(l.holderName) until \(l.expires.formatted(date: .omitted, time: .shortened))"))
                            .foregroundStyle(.secondary)
                        if l.holder == c.myKey { Button(String(localized: "Continue")) { activeBatch = b } }
                    } else {
                        Button(String(localized: "Check out")) {
                            do {
                                if try c.checkout(b, state: state) { reload(); activeBatch = b }
                                else { status = String(localized: "Someone else has just checked out this batch.") }
                            } catch { status = error.localizedDescription }
                        }
                    }
                }
            }
        } header: { Text("Batches") }

        if !state.conflicts.isEmpty {
            Section {
                ForEach(state.conflicts) { k in
                    VStack(alignment: .leading) {
                        Text(c.evidence.index.first { $0.id == k.emailID }?.subject ?? k.emailID.uuidString)
                        Text(k.decisions.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " · ")).font(.caption)
                        if isLead {
                            HStack {
                                ForEach(c.manifest.codes, id: \.self) { code in
                                    Button(code) {
                                        try? c.append(.resolve, emailID: k.emailID, value: code, state: state); reload()
                                    }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            } header: { Text("Conflicts") }
        }

        let qc = c.qcQueue(state: state)
        Section {
            Text("\(qc.count) emails waiting for second-level review.")
            ForEach(state.qcStats(), id: \.reviewer) { r in
                Text("\(r.reviewer): \(r.overturned) of \(r.checked) overturned (\(Int(r.rate * 100)) %, 95 % interval \(Int(r.low * 100))–\(Int(r.high * 100)) %)")
                    .font(.caption)
            }
        } header: { Text("Quality control") }

        Section {
            Button(String(localized: "Export merged audit trail (JSON Lines)…")) {
                status = PlatformExport.save(data: c.mergedAudit(), suggestedName: "\(c.manifest.title) audit.jsonl")
                    .message(String(localized: "Audit trail"))
            }
            if isLead {
                Button(String(localized: "Apply resolved codes and tags to my archive")) {
                    Task {
                        do {
                            let r = try await c.applyToArchive(state: state)
                            status = String(localized: "Applied \(r.codes) codes and \(r.tags) tags; \(r.skipped) emails kept the code already in your archive.")
                        } catch { status = error.localizedDescription }
                    }
                }
            }
        } header: { Text("Results") }
    }

    private func reload() {
        guard let c = teamCase else { return }
        state = c.load()
    }

    private func open(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()   // kept for the session: the case is read and written while open
        do {
            let c = try TeamCase(folder: url, name: myName, role: OrgPolicy.role.rawValue)
            teamCase = c
            reload()
            if state.members[c.myKey] == nil { try c.append(.join, state: state); reload() }
        } catch {
            status = error.localizedDescription
        }
    }

    private func create(in parent: URL) async {
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        creating = true
        defer { creating = false }
        do {
            let scope = ArchiveScope(query: ArchiveQueryCompiler.compile(search), total: nil, loaded: nil)
            let folder = try await TeamCase.create(in: parent, title: title, scope: scope, batchSize: batchSize,
                                                   qcPercent: qcPercent) { done, total in
                progress = total > 0 ? Double(done) / Double(total) : 1
            }
            open(folder)
            status = String(localized: "Case created. Share the folder \(folder.lastPathComponent) with the team.")
        } catch {
            status = error.localizedDescription
        }
    }
}

struct TeamBatchReviewView: View {
    let teamCase: TeamCase
    let batch: Int
    @Binding var state: TeamCaseState
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var current: ReviewPackEmail?
    @State private var tagText = ""
    @State private var noteText = ""
    @State private var error: String?

    private var ids: [UUID] { teamCase.manifest.batches[batch] }

    var body: some View {
        NavigationSplitView {
            List(ids, id: \.self, selection: $selection) { id in
                let entry = teamCase.evidence.index.first { $0.id == id }
                HStack {
                    Text(entry?.subject ?? id.uuidString).lineLimit(1)
                    Spacer()
                    if let code = state.emails[id]?.codes[teamCase.myKey] { Text(code).font(.caption).foregroundStyle(.tint) }
                    if state.emails[id]?.reviewLater.contains(teamCase.myKey) == true { Image(systemName: "clock") }
                }
            }
            .navigationTitle("Batch \(batch + 1)")
        } detail: {
            VStack(alignment: .leading, spacing: Spacing.small) {
                let mine = ids.filter { state.emails[$0]?.codes[teamCase.myKey] != nil }.count
                Text("\(mine) of \(ids.count) coded").font(.caption)
                if let e = current {
                    Text(e.subject).font(.headline)
                    Text("From \(e.from) · \(e.date)").font(.caption)
                    ScrollView { Text(e.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        ForEach(teamCase.manifest.codes, id: \.self) { code in
                            Button(code) { write(.code, e.id, code); advance() }.buttonStyle(.bordered)
                        }
                        Button(String(localized: "Review later")) { write(.reviewLater, e.id, "on"); advance() }
                    }
                    HStack {
                        TextField(String(localized: "Tag"), text: $tagText).onSubmit { write(.tagAdd, e.id, tagText); tagText = "" }
                        TextField(String(localized: "Note"), text: $noteText).onSubmit { write(.note, e.id, noteText); noteText = "" }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button(String(localized: "Release batch")) { try? teamCase.release(batch, done: false, state: state); dismiss() }
                    Button(String(localized: "Mark batch done")) { try? teamCase.release(batch, done: true, state: state); state = teamCase.load(); dismiss() }
                        .disabled(!teamCase.batchComplete(batch, state: state))
                }
            }
            .padding()
        }
        .onAppear { selection = teamCase.firstUncoded(batch, state: state) ?? ids.first }
        .onChange(of: selection) { _, id in
            guard let id, let i = teamCase.evidence.index.firstIndex(where: { $0.id == id }) else { current = nil; return }
            current = try? teamCase.evidence.email(at: i)
        }
    }

    private func write(_ op: TeamLogEntry.Op, _ id: UUID, _ value: String) {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Read-only when the batch is no longer ours or is completed.
        guard teamCase.lease(batch)?.holder == teamCase.myKey, !state.batchDone.contains(batch) else {
            error = String(localized: "This batch is no longer checked out to you; it is read-only.")
            return
        }
        do {
            try teamCase.append(op, emailID: id, value: value, state: state)
            state = teamCase.load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func advance() {
        selection = teamCase.firstUncoded(batch, state: state) ?? selection
    }
}
