//
//  ContainerReconciliation.swift
//  ArchiveCore
//
//  Release audit bf1a5b9 R3: an mbox / PST output checked one-to-one against
//  the expected occurrences its export wrote (`ContainerManifest`).
//
//  Pass 1 walks the output and the manifest together. The i-th output message
//  normally IS the i-th expected record: equal content fingerprints (or, for a
//  record that was header-only at export, equal Message-IDs) pair them, and
//  the pair is compared field by field at once against the archive record
//  looked up by its ID — never by Message-ID. Anything out of step is parked:
//  outputs and expected records waiting for a partner, paired as soon as the
//  fingerprint of one turns up on the other side. Memory grows with the
//  disorder of the file only, not with its size.
//
//  Then the parked remainder is resolved, in this order:
//   1. an output whose fingerprint is that of an expected record already
//      consumed is a SECOND COPY of it — extra, never a match;
//   2. an output and an expected record with the same Message-ID are paired
//      (Message-ID is a hint here, not the identity) and compared;
//   3. an output and an expected record at the same place in the file, when
//      one of them has no Message-ID, are paired and compared;
//   4. every expected record left is MISSING; every output left is EXTRA,
//      named as an archive record outside the selection when its Message-ID
//      finds one that the manifest does not list.
//  Pairs made after pass 1 are compared in a second pass over the file, which
//  runs only when there are such pairs.
//
//  Any missing or extra occurrence fails the check.
//

import Foundation

extension ExportReconciliation {

    /// Counts the item into `report` (only non-matching items are retained).
    static func tally(_ item: Item, into report: inout ContentReport) {
        if !item.fields.isEmpty { report.checked += 1 }
        switch item.status {
        case .matching: report.matching += 1
        case .mismatched: report.mismatched += 1; report.findings.append(item)
        case .unverifiable: report.unverifiable += 1; report.findings.append(item)
        case .withoutRecord: report.withoutRecord += 1; report.findings.append(item)
        case .unparsed: report.unparsed += 1; report.findings.append(item)
        case .missing:
            report.selection = report.selection ?? SelectionCheck()
            report.selection?.missing += 1; report.findings.append(item)
        case .extra:
            report.selection = report.selection ?? SelectionCheck()
            report.selection?.extra += 1; report.findings.append(item)
        }
        for name in item.transformations { report.transformations[name, default: 0] += 1 }
    }

    /// The bounded container reader, batch by batch.
    static func readContainer(_ url: URL, kind: OutputKind, batchSize: Int,
                              _ onBatch: ([MBOXParser.RawEmail]) async throws -> Void) async throws {
        switch kind {
        case .mbox:
            _ = try await MBOXParser.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: batchSize) { batch in
                defer { for email in batch { removeScratch(of: email) } }
                try await onBatch(batch)
            }
        case .pst:
            _ = try await PSTParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: batchSize) { batch in
                defer { for email in batch { removeScratch(of: email) } }
                try await onBatch(batch)
            }
        default:
            break
        }
    }

    /// One expected occurrence, as the manifest lists it.
    struct ExpectedOccurrence: Sendable {
        let ordinal: Int
        let emailID: UUID?
        let messageID: String?
        let fingerprint: String?
        init(_ line: ContainerManifest.Line) {
            ordinal = line.ordinal ?? -1
            emailID = line.emailID.flatMap(UUID.init(uuidString:))
            messageID = line.messageID.map(identifier).flatMap { $0.isEmpty ? nil : $0 }
            fingerprint = line.fingerprint
        }
    }

    private struct ParkedOutput { let ordinal: Int; let fingerprint: String; let messageID: String? }

    /// Pass 1 + resolution + pass 2 for one container with a manifest.
    static func reconcileWithManifest(_ output: OutputRecord, manifestURL: URL, scan: ContainerManifest.Scan,
                                      lookup: SourceLookup, pageSize: Int, report: inout ContentReport) async throws {
        var selection = report.selection ?? SelectionCheck()
        selection.manifests += 1
        selection.expected += scan.recordLines
        if scan.end == nil { selection.unfinishedManifests += 1 }
        report.selection = selection

        let kind = output.kind, path = output.path
        let rules = FormatRules.rules(for: kind)
        let cursor = try ContainerManifest.RecordCursor(url: manifestURL)
        var outputOrdinal = 0
        var parkedExpected: [Int: ExpectedOccurrence] = [:]
        var expectedByFingerprint: [String: [Int]] = [:]
        var parkedOutputs: [Int: ParkedOutput] = [:]
        var outputsByFingerprint: [String: [Int]] = [:]
        var deferred: [Int: ExpectedOccurrence] = [:]   // output ordinal → its expected occurrence

        func take(_ list: inout [Int]?, preferring messageID: String?, from pool: [Int: ExpectedOccurrence]) -> Int? {
            guard var ords = list, !ords.isEmpty else { return nil }
            let pick = ords.firstIndex { pool[$0]?.messageID == messageID } ?? 0
            let ord = ords.remove(at: pick)
            list = ords.isEmpty ? nil : ords
            return ord
        }
        /// Parks an expected occurrence, unless a parked output already has its fingerprint.
        func park(_ e: ExpectedOccurrence) {
            if let fp = e.fingerprint, var ords = outputsByFingerprint[fp], !ords.isEmpty {
                let pick = ords.firstIndex { parkedOutputs[$0]?.messageID == e.messageID } ?? 0
                let o = ords.remove(at: pick)
                outputsByFingerprint[fp] = ords.isEmpty ? nil : ords
                parkedOutputs[o] = nil
                deferred[o] = e
                return
            }
            parkedExpected[e.ordinal] = e
            if let fp = e.fingerprint { expectedByFingerprint[fp, default: []].append(e.ordinal) }
        }
        func inStep(_ e: ExpectedOccurrence, fingerprint: String, messageID: String?) -> Bool {
            if let efp = e.fingerprint { return efp == fingerprint }
            return e.messageID == messageID
        }

        // Pass 1.
        var hydratedCount = 0
        var local = report
        do {
            try await readContainer(output.url, kind: kind, batchSize: pageSize) { batch in
                var pairs: [(parsed: MBOXParser.RawEmail, expected: ExpectedOccurrence, ordinal: Int)] = []
                for parsed in batch {
                    outputOrdinal += 1
                    local.eligible += 1
                    let fp = ContainerManifest.fingerprint(of: parsed, allowHeaderOnly: true) ?? ""
                    let mid = header("Message-ID", parsed.headers).map(identifier).flatMap { $0.isEmpty ? nil : $0 }
                    if let e = try cursor.next().map(ExpectedOccurrence.init) {
                        if inStep(e, fingerprint: fp, messageID: mid) { pairs.append((parsed, e, outputOrdinal)); continue }
                        park(e)
                    }
                    var list = expectedByFingerprint[fp]
                    if let ord = take(&list, preferring: mid, from: parkedExpected), let e = parkedExpected.removeValue(forKey: ord) {
                        expectedByFingerprint[fp] = list
                        deferred[outputOrdinal] = e
                        continue
                    }
                    parkedOutputs[outputOrdinal] = ParkedOutput(ordinal: outputOrdinal, fingerprint: fp, messageID: mid)
                    outputsByFingerprint[fp, default: []].append(outputOrdinal)
                }
                let ids = pairs.compactMap(\.expected.emailID)
                let sources = ids.isEmpty ? [:] : try await lookup.records(ids)
                for pair in pairs {
                    let item = try await compareOccurrence(pair.parsed, ordinal: pair.ordinal, expected: pair.expected,
                                                           sources: sources, path: path, rules: rules, lookup: lookup,
                                                           hydrated: &hydratedCount)
                    tally(item, into: &local)
                }
            }
        } catch {
            local.hydrated += hydratedCount
            report = local
            throw error
        }
        // The output ended: every expected occurrence not yet read is parked.
        while let line = try cursor.next() { park(ExpectedOccurrence(line)) }

        // Resolution 1: a parked output whose content is that of a record
        // already consumed is a second copy of it. Resolution 4 needs to know
        // whether an archive record found by Message-ID is in the selection.
        var archiveMatch: [Int: UUID] = [:]
        if !parkedOutputs.isEmpty, let byMID = lookup.recordsByMessageID {
            let mids = Array(Set(parkedOutputs.values.compactMap(\.messageID)))
            var start = 0
            var found: [String: UUID] = [:]
            while start < mids.count {
                let page = Array(mids[start..<min(start + pageSize, mids.count)])
                start += pageSize
                for (key, value) in try await byMID(page) { found[identifier(key)] = value.id }
            }
            for (o, info) in parkedOutputs { if let mid = info.messageID, let id = found[mid] { archiveMatch[o] = id } }
        }
        var copyOf: [Int: (ordinal: Int, emailID: String?)] = [:]
        var listedIDs = Set<UUID>()
        if !parkedOutputs.isEmpty {
            let wantedFingerprints = Set(parkedOutputs.values.map(\.fingerprint))
            let wantedIDs = Set(archiveMatch.values)
            var firstWithFingerprint: [String: (Int, String?)] = [:]
            try ContainerManifest.forEachLine(url: manifestURL) { line, _ in
                guard line.kind == .record else { return true }
                if let fp = line.fingerprint, wantedFingerprints.contains(fp), firstWithFingerprint[fp] == nil, parkedExpected[line.ordinal ?? -1] == nil {
                    firstWithFingerprint[fp] = (line.ordinal ?? -1, line.emailID)
                }
                if let id = line.emailID.flatMap(UUID.init(uuidString:)), wantedIDs.contains(id) { listedIDs.insert(id) }
                return true
            }
            for (o, info) in parkedOutputs {
                if let first = firstWithFingerprint[info.fingerprint] { copyOf[o] = first }
            }
        }
        var extras: [Item] = []
        for (o, first) in copyOf.sorted(by: { $0.key < $1.key }) {
            let info = parkedOutputs.removeValue(forKey: o)
            outputsByFingerprint[info?.fingerprint ?? ""] = nil
            extras.append(Item(path: "\(path)#\(o)", emailID: first.emailID.flatMap(UUID.init(uuidString:)), messageID: info?.messageID, status: .extra,
                               reason: "a second copy of the record listed at #\(first.ordinal + 1) (\(first.emailID ?? "no ID")); each selected record is written once", fields: []))
        }
        // Resolution 2: Message-ID as a hint.
        var expectedByMID: [String: [Int]] = [:]
        for (ord, e) in parkedExpected { if let mid = e.messageID { expectedByMID[mid, default: []].append(ord) } }
        for key in expectedByMID.keys { expectedByMID[key]?.sort() }
        for o in parkedOutputs.keys.sorted() {
            guard let mid = parkedOutputs[o]?.messageID, var ords = expectedByMID[mid], !ords.isEmpty else { continue }
            let ord = ords.removeFirst()
            expectedByMID[mid] = ords
            if let e = parkedExpected.removeValue(forKey: ord) { deferred[o] = e; parkedOutputs[o] = nil }
        }
        // Resolution 3: the same place in the file, when a Message-ID is absent.
        for o in parkedOutputs.keys.sorted() {
            guard let e = parkedExpected[o - 1], e.messageID == nil || parkedOutputs[o]?.messageID == nil else { continue }
            parkedExpected[o - 1] = nil
            parkedOutputs[o] = nil
            deferred[o] = e
        }
        // Resolution 4: what is left.
        for (o, info) in parkedOutputs.sorted(by: { $0.key < $1.key }) {
            let reason: String
            if let id = archiveMatch[o], !listedIDs.contains(id) {
                reason = "matches archive record \(id.uuidString), which is not in this export's selection"
            } else if lookup.recordsByMessageID != nil, info.messageID != nil, archiveMatch[o] == nil {
                reason = "not in this export's selection, and no archive record has its Message-ID"
            } else {
                reason = "not in this export's selection"
            }
            extras.append(Item(path: "\(path)#\(o)", emailID: archiveMatch[o], messageID: info.messageID, status: .extra, reason: reason, fields: []))
        }
        for item in extras.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) { tally(item, into: &local) }
        for (ord, e) in parkedExpected.sorted(by: { $0.key < $1.key }) {
            tally(Item(path: "\(path) expected #\(ord + 1)", emailID: e.emailID, messageID: e.messageID, status: .missing,
                       reason: "selected record \(e.emailID?.uuidString ?? "?")\(e.messageID.map { " (Message-ID \($0))" } ?? "") is not in the output",
                       fields: []), into: &local)
        }

        // Pass 2: compare the pairs made after pass 1.
        if !deferred.isEmpty {
            var ordinal = 0
            try await readContainer(output.url, kind: kind, batchSize: pageSize) { batch in
                var pairs: [(MBOXParser.RawEmail, ExpectedOccurrence, Int)] = []
                for parsed in batch {
                    ordinal += 1
                    if let e = deferred[ordinal] { pairs.append((parsed, e, ordinal)) }
                }
                guard !pairs.isEmpty else { return }
                let ids = pairs.compactMap(\.1.emailID)
                let sources = ids.isEmpty ? [:] : try await lookup.records(ids)
                for (parsed, e, o) in pairs {
                    let item = try await compareOccurrence(parsed, ordinal: o, expected: e, sources: sources, path: path,
                                                           rules: rules, lookup: lookup, hydrated: &hydratedCount)
                    tally(item, into: &local)
                }
            }
        }
        local.hydrated += hydratedCount
        local.selection?.paired += scan.recordLines - parkedExpected.count
        local.selection?.pairedOutOfOrder += deferred.count
        report = local
    }

    /// One output message against the archive record its expected occurrence names.
    private static func compareOccurrence(_ parsed: MBOXParser.RawEmail, ordinal: Int, expected: ExpectedOccurrence,
                                          sources: [UUID: MBOXParser.RawEmail], path: String, rules: FormatRules,
                                          lookup: SourceLookup, hydrated: inout Int) async throws -> Item {
        let itemPath = "\(path)#\(ordinal)"
        let mid = header("Message-ID", parsed.headers).map(identifier)
        guard let id = expected.emailID else {
            return Item(path: itemPath, emailID: nil, messageID: mid, status: .withoutRecord,
                        reason: "the manifest lists no archive ID for this record", fields: [])
        }
        guard var source = sources[id] else {
            return Item(path: itemPath, emailID: id, messageID: mid, status: .withoutRecord,
                        reason: "record \(id.uuidString) is not in the archive", fields: [])
        }
        var wasHydrated = false
        if isHeaderOnly(source) {
            if let hydrate = lookup.hydrate, let full = try await hydrate(source.id), !isHeaderOnly(full) {
                source = full; wasHydrated = true
            } else if let full = hydrateFromLocatedSource(source) {
                source = full; wasHydrated = true
            }
            if wasHydrated { hydrated += 1 }
        }
        let fields = compare(output: parsed, source: source, rules: rules, outputFolder: parsed.folderPath, sourceHydrated: wasHydrated)
        return item(path: itemPath, emailID: id, messageID: mid, fields: fields)
    }
}
