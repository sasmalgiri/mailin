//
//  ForensicSignalsView.swift
//  maxmailin
//
//  3.1 F1–F4 panel in the email detail: every timestamp the message carries,
//  the Received trace, missing-DKIM and tampering signals, and an offline DKIM
//  check against keys the examiner imported. Hidden while
//  Capability.v31ForensicTimestamps is off.
//

import SwiftUI
import UniformTypeIdentifiers
@testable import ArchiveCore

enum DKIMKeyStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dkim-keys.json")
    }

    static func load() -> DKIMKeyCache {
        guard let d = try? Data(contentsOf: url) else { return DKIMKeyCache() }
        return (try? JSONDecoder().decode(DKIMKeyCache.self, from: d)) ?? DKIMKeyCache()
    }

    /// Adds the records in a text file (`selector._domainkey.domain  "v=DKIM1; …"` per line).
    static func importFile(_ text: String) throws -> Int {
        var cache = load()
        let added = DKIMKeyCache.parse(text)
        cache.records.merge(added.records) { _, new in new }
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
        return added.records.count
    }
}

struct ForensicSignalsView: View {
    let email: MBOXParser.RawEmail
    @State private var expanded = false
    @State private var dkim: DKIMResult?
    @State private var arc: DKIMResult?
    @State private var arcChain: DKIMVerifier.ARCResult?
    @State private var showKeyImport = false
    @State private var keyStatus: String?

    var body: some View {
        if ForensicSignalsPolicy.isEnabled && TierAccess.allows(.forensicSignals) {
            DisclosureGroup(isExpanded: $expanded) {
                content
            } label: {
                Label("Timestamps & signals", systemImage: "clock.badge.questionmark")
            }
            .fileImporter(isPresented: $showKeyImport, allowedContentTypes: [.plainText, .text, .data]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let n = try DKIMKeyStore.importFile(try String(contentsOf: url, encoding: .utf8))
                    keyStatus = String(localized: "\(n) DKIM keys imported.")
                    dkim = DKIMVerifier.verify(rawSource: email.rawSource, keys: DKIMKeyStore.load())
                } catch {
                    keyStatus = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let stamps = HiddenTimestamps.all(headers: email.headers, rawSource: email.rawSource)
        let hops = ReceivedTrace.hops(rawSource: email.rawSource)
        let date = email.headers["Date"].flatMap(RFC5322Date.parse)
        let missing = DKIMExpectations.missingSignature(headers: email.headers, rawSource: email.rawSource, date: date)
        let tamper = TamperingSignals.find(headers: email.headers, rawSource: email.rawSource, attachmentCount: email.attachments.count)

        VStack(alignment: .leading, spacing: Spacing.small) {
            if !tamper.isEmpty || missing != nil {
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    ForEach((missing.map { [$0] } ?? []) + tamper, id: \.self) { s in
                        Label(s, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                }
            }

            Text("Timeline (UTC)").font(.subheadline.weight(.semibold))
            if stamps.isEmpty {
                Text("No timestamps could be read.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(stamps.indices, id: \.self) { i in
                HStack(alignment: .top) {
                    Text(stamps[i].date.ISO8601Format()).font(.caption.monospaced())
                    Text(stamps[i].source).font(.caption)
                }
            }

            Text("Received trace").font(.subheadline.weight(.semibold))
            if hops.isEmpty {
                Text("No Received headers.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hops, id: \.index) { h in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(h.index). \(h.from.isEmpty ? "?" : h.from) → \(h.by.isEmpty ? "?" : h.by)\(h.with.isEmpty ? "" : " (\(h.with))")")
                        .font(.caption)
                    HStack {
                        Text(h.date.map { $0.ISO8601Format() } ?? String(localized: "no date")).font(.caption2.monospaced())
                        if let d = h.delay {
                            Text(d < 0 ? String(localized: "\(Int(-d)) s earlier than the previous hop") : String(localized: "+\(Int(d)) s"))
                                .font(.caption2).foregroundStyle(d < -300 ? .orange : .secondary)
                        }
                    }
                }
            }

            Text("DKIM (offline)").font(.subheadline.weight(.semibold))
            HStack {
                Button(String(localized: "Check signature")) {
                    let keys = DKIMKeyStore.load()
                    dkim = DKIMVerifier.verify(rawSource: email.rawSource, keys: keys)
                    let a = DKIMVerifier.verify(rawSource: email.rawSource, keys: keys, signatureHeader: "ARC-Message-Signature")
                    arc = a == .noSignature ? nil : a
                    let chain = DKIMVerifier.verifyARCChain(rawSource: email.rawSource, keys: keys)
                    arcChain = chain == .none ? nil : chain
                }
                Button(String(localized: "Import DKIM keys…")) { showKeyImport = true }
            }
            if let dkim { Text(Self.describe(dkim)).font(.callout) }
            if let arc { Text(String(localized: "ARC message signature: ") + Self.describe(arc)).font(.callout) }
            if let arcChain { Text(Self.describe(arcChain)).font(.callout) }
            if let keyStatus { Text(keyStatus).font(.caption) }
            Text("mailin never looks keys up online. Import the domain's DKIM records (captured at collection, or from the sender's DNS) as a text file: one `selector._domainkey.domain  \"v=DKIM1; k=rsa; p=…\"` per line.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    static func describe(_ r: DKIMVerifier.ARCResult) -> String {
        switch r {
        case .none: return ""
        case .pass(let n): return String(localized: "ARC chain: pass — \(n) forwarding hops, every seal verifies.")
        case .fail(let i, let why): return String(localized: "ARC chain: fail at hop \(i) — \(why).")
        case .noKey(let i, let d, let s): return String(localized: "ARC chain: no key for \(s)._domainkey.\(d) (hop \(i)). Import it to check the chain.")
        }
    }

    static func describe(_ r: DKIMResult) -> String {
        switch r {
        case .pass(let d, let s): return String(localized: "Pass: signed by \(d) (selector \(s)); headers and body are as signed.")
        case .fail(let why): return String(localized: "Fail: \(why).")
        case .noKey(let d, let s): return String(localized: "No key for \(s)._domainkey.\(d). Import it to check this signature.")
        case .noSignature: return String(localized: "The message has no DKIM signature.")
        case .unsupported(let why): return String(localized: "Cannot check: \(why).")
        }
    }
}
