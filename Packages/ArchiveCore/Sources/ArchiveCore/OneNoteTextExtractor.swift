//
//  OneNoteTextExtractor.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Other business formats": Microsoft OneNote
//  sections (.one) and notebook packages (.onepkg). A section written by
//  OneNote 2010 and later is an MS-ONESTORE revision store: a 1,024-byte
//  header names the root file node list; file node lists are chains of
//  fragments (magic 0xA4567AB1F5F7F4C4, footer 0x8BC215C38233BA4B) of
//  FileNode records; every revision manifest list is one object space (the
//  section itself or one page); each revision carries a global id table
//  that resolves the 4-byte CompactIDs objects use to name each other;
//  an object declaration points at an ObjectSpaceObjectPropSet whose
//  properties carry the notes — RichEditTextUnicode (0x1C001C22, UTF-16LE
//  to the first NUL), CachedTitleString (0x1C001CF3), TextExtendedAscii
//  (0x1C003498) — and the CompactIDs of child objects (outline → outline
//  element → rich text). This reader follows Apache Tika's OneNoteParser:
//  for every object space the latest revision with role 1 is chosen, its
//  root object (root role 1) walked through child references, and each
//  text run emitted once (MS-ONESTORE §2.1–2.6, MS-ONE §2.3).
//
//  A section saved in the alternative packaging (file format
//  {638DE92F-A6D4-4BC1-9A36-B3FC2511A5B7}; Office 365 exports and some
//  2007-era files) wraps the revision store in an MS-FSSHTTPB data element
//  package. That package is read element by element (16/32-bit stream
//  object headers, compact uint64, extended GUIDs); every object group's
//  partition-1 objects carry the same ObjectSpaceObjectPropSet, so their
//  text is read in storage order with the newest revision of each object
//  winning. The page tree of that layout is not rebuilt: the output says
//  so. A section whose structure cannot be followed (truncated, damaged,
//  or a pre-2010 layout that is not documented) falls back to scanning for
//  ASCII and UTF-16LE strings, labelled as recovered text, so a damaged
//  file still indexes what it visibly holds — the note says it is a scan.
//
//  A .onepkg is a Microsoft cabinet (CabinetReader): every .one member is
//  read as above under "[OneNote section: name]"; a table of contents or
//  other member is listed as not text; an LZX- or Quantum-compressed folder
//  is named and not opened. A section with an ObjectDataEncryptionKeyV2FNDX
//  node (or an FSSHTTPB encryption-key root) and no readable text is
//  reported password-protected. Embedded files (FileDataStoreObject) are
//  counted as not text. Nothing is executed and no link is followed.
//

import Foundation

enum OneNoteTextExtractor {

    static let component = "OneNote text"
    static let recoveredComponent = "Recovered text"

    /// {7B5C52E4-D88C-4DA7-AEB1-5378D02996D3} — guidFileType of a section (.one).
    static let sectionFileTypeGUID: [UInt8] = [0xE4, 0x52, 0x5C, 0x7B, 0x8C, 0xD8, 0xA7, 0x4D, 0xAE, 0xB1, 0x53, 0x78, 0xD0, 0x29, 0x96, 0xD3]
    /// {43FF2FA1-EFD9-4C76-9EE2-10EA5722765F} — guidFileType of a table of contents (.onetoc2).
    static let tocFileTypeGUID: [UInt8] = [0xA1, 0x2F, 0xFF, 0x43, 0xD9, 0xEF, 0x76, 0x4C, 0x9E, 0xE2, 0x10, 0xEA, 0x57, 0x22, 0x76, 0x5F]
    /// {109ADD3F-911B-49F5-A5D0-1791EDC8AED8} — guidFileFormat of the MS-ONESTORE revision store.
    static let oneStoreFormatGUID: [UInt8] = [0x3F, 0xDD, 0x9A, 0x10, 0x1B, 0x91, 0xF5, 0x49, 0xA5, 0xD0, 0x17, 0x91, 0xED, 0xC8, 0xAE, 0xD8]
    /// {638DE92F-A6D4-4BC1-9A36-B3FC2511A5B7} — guidFileFormat of the FSSHTTPB alternative packaging.
    static let packagingFormatGUID: [UInt8] = [0x2F, 0xE9, 0x8D, 0x63, 0xD4, 0xA6, 0xC1, 0x4B, 0x9A, 0x36, 0xB3, 0xFC, 0x25, 0x11, 0xA5, 0xB7]

    static let richEditTextUnicode: UInt32 = 0x1C00_1C22
    static let cachedTitleString: UInt32 = 0x1C00_1CF3
    static let textExtendedAscii: UInt32 = 0x1C00_3498
    static let elementChildNodesOfVersionHistory: UInt32 = 0x2400_1C20

    struct Issue: Error { let text: String; init(_ text: String) { self.text = text } }

    static func hasSectionSignature(_ head: Data) -> Bool {
        head.count >= 16 && Array(head.prefix(16)) == sectionFileTypeGUID
    }

    // MARK: - Entry points

    static func extract(fileURL: URL, logicalName: String?) throws -> OfficeTextExtractor.Result {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let name = logicalName ?? fileURL.lastPathComponent
        let limit = ExtractionLimits.effective.partBytes
        guard Int64(data.count) <= limit else {
            return OfficeTextExtractor.Result(text: "", components: [], skipped: ["\(name) (\(data.count) bytes, over the \(limit)-byte guard)"], notText: [])
        }
        return try extract(data: data, name: name)
    }

    /// One section's text (exposed for tests and for the package reader).
    static func extract(data: Data, name: String) throws -> OfficeTextExtractor.Result {
        let bytes = [UInt8](data)
        guard bytes.count >= 64 else { throw OfficeTextExtractor.ExtractError.notAPackage("too short to be a OneNote file (\(bytes.count) bytes)") }
        guard Array(bytes[0..<16]) == sectionFileTypeGUID else {
            if Array(bytes[0..<16]) == tocFileTypeGUID { throw OfficeTextExtractor.ExtractError.notAPackage("a OneNote table of contents (.onetoc2) carries no notes") }
            throw OfficeTextExtractor.ExtractError.notAPackage("not a OneNote section file")
        }
        let sectionName = (name as NSString).deletingPathExtension
        let fileFormat = Array(bytes[48..<64])
        let legacyVersionIsNil = bytes[32..<48].allSatisfy { $0 == 0 }

        var blocks: [(label: String, lines: [String])] = []
        var skipped: [String] = []
        var notText: [String] = []
        var encrypted = false
        var structureFailed = false

        if fileFormat == oneStoreFormatGUID && legacyVersionIsNil {
            let store = OneStoreFile(bytes: bytes)
            store.parse()
            let collected = store.collectText()
            for (index, page) in collected.pages.enumerated() { blocks.append(("Page \(index + 1)", page)) }
            if !collected.otherObjects.isEmpty { blocks.append(("Earlier revisions and other objects", collected.otherObjects)) }
            encrypted = store.encrypted
            structureFailed = blocks.isEmpty && !store.issues.isEmpty
            skipped.append(contentsOf: store.issues.map { "\(name): \($0)" })
            if store.depthLimitHit { skipped.append("\(name): objects nested deeper than \(OneStoreFile.maxWalkDepth) levels were not followed") }
            notText.append(contentsOf: store.embeddedFiles.enumerated().map { "\(name): embedded file \($0.offset + 1) (\($0.element) bytes)" })
        } else if fileFormat == packagingFormatGUID {
            let package = PackagedStore(bytes: bytes)
            package.parse()
            let lines = package.collectText()
            if !lines.isEmpty { blocks.append(("Packaged layout (FSSHTTPB) — text in storage order, pages not separated", lines)) }
            encrypted = package.encrypted
            structureFailed = lines.isEmpty
            skipped.append(contentsOf: package.issues.map { "\(name): \($0)" })
            notText.append(contentsOf: package.embeddedFiles.enumerated().map { "\(name): embedded file \($0.offset + 1) (\($0.element) bytes)" })
        } else {
            skipped.append("\(name): file format \(guidString(fileFormat)) is not the documented OneNote 2010+ layout; text recovered by scanning for strings")
            structureFailed = true
        }

        var components: [String] = []
        var text = "[OneNote section: \(sectionName)]\n"
        if !blocks.isEmpty {
            components.append(component)
            for block in blocks { text += "[\(block.label)]\n" + block.lines.joined(separator: "\n") + "\n" }
        }
        if structureFailed {
            let recovered = recoveredStrings(bytes)
            if !recovered.isEmpty {
                if blocks.isEmpty, fileFormat == oneStoreFormatGUID || fileFormat == packagingFormatGUID {
                    skipped.append("\(name): the note structure could not be followed; text recovered by scanning for strings (order and completeness not guaranteed)")
                }
                components.append(recoveredComponent)
                text += "[Text recovered by scanning]\n" + recovered.joined(separator: "\n") + "\n"
            }
        }
        if components.isEmpty {
            if encrypted { throw OfficeTextExtractor.ExtractError.encrypted }
            if skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
            return OfficeTextExtractor.Result(text: "", components: [], skipped: skipped, notText: notText)
        }
        if encrypted { skipped.append("\(name): password-protected content was not read") }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText)
    }

    /// A .onepkg notebook: a cabinet of sections.
    static func extractPackage(fileURL: URL, logicalName: String?) throws -> OfficeTextExtractor.Result {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let name = logicalName ?? fileURL.lastPathComponent
        guard CabinetReader.hasSignature(data) else { throw OfficeTextExtractor.ExtractError.notAPackage("not a cabinet (.onepkg) file") }
        let limit = ExtractionLimits.effective.partBytes
        guard Int64(data.count) <= limit else {
            return OfficeTextExtractor.Result(text: "", components: [], skipped: ["\(name) (\(data.count) bytes, over the \(limit)-byte guard)"], notText: [])
        }
        let cabinet: CabinetReader
        do { cabinet = try CabinetReader(data: data) } catch { throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error)) }

        var text = "[OneNote notebook: \((name as NSString).deletingPathExtension)]\n"
        var components: [String] = []
        var skipped: [String] = []
        var notText: [String] = []
        for member in cabinet.members {
            let lower = member.name.lowercased()
            guard lower.hasSuffix(".one") else {
                if lower.hasSuffix(".onetoc2") { notText.append("\(member.name) (table of contents)") }
                else { notText.append("\(member.name) (\(member.size) bytes, not a section)") }
                continue
            }
            let folder = cabinet.folders[member.folderIndex]
            guard folder.compression.isReadable else {
                skipped.append("\(member.name) (\(folder.compression.name)-compressed cabinet folder, not opened)")
                continue
            }
            guard Int64(member.size) <= limit else {
                skipped.append("\(member.name) (\(member.size) bytes, over the \(limit)-byte guard)")
                continue
            }
            do {
                let bytes = try cabinet.extract(member)
                let result = try extract(data: Data(bytes), name: member.name)
                text += result.text + "\n"
                for c in result.components where !components.contains(c) { components.append(c) }
                skipped.append(contentsOf: result.skipped)
                notText.append(contentsOf: result.notText)
            } catch OfficeTextExtractor.ExtractError.encrypted {
                skipped.append("\(member.name) (password-protected)")
            } catch OfficeTextExtractor.ExtractError.noTextParts {
                notText.append("\(member.name) (no text)")
            } catch {
                skipped.append("\(member.name) (\(error.localizedDescription))")
            }
        }
        skipped.append(contentsOf: cabinet.notes)
        if components.isEmpty {
            if skipped.isEmpty && notText.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
            return OfficeTextExtractor.Result(text: "", components: [], skipped: skipped, notText: notText)
        }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText)
    }

    // MARK: - Shared byte cursor

    struct Cursor {
        let b: [UInt8]
        var pos: Int
        var end: Int

        init(_ b: [UInt8], pos: Int, end: Int) { self.b = b; self.pos = pos; self.end = min(end, b.count) }

        var remaining: Int { end - pos }

        mutating func u8() throws -> UInt8 {
            guard pos >= 0, pos < end else { throw Issue("read past the end of the structure at offset \(pos)") }
            defer { pos += 1 }
            return b[pos]
        }
        mutating func u16() throws -> UInt16 {
            guard pos >= 0, pos + 2 <= end else { throw Issue("read past the end of the structure at offset \(pos)") }
            defer { pos += 2 }
            return UInt16(b[pos]) | UInt16(b[pos + 1]) << 8
        }
        mutating func u32() throws -> UInt32 {
            guard pos >= 0, pos + 4 <= end else { throw Issue("read past the end of the structure at offset \(pos)") }
            defer { pos += 4 }
            return UInt32(b[pos]) | UInt32(b[pos + 1]) << 8 | UInt32(b[pos + 2]) << 16 | UInt32(b[pos + 3]) << 24
        }
        mutating func u64() throws -> UInt64 {
            let low = UInt64(try u32()), high = UInt64(try u32())
            return low | high << 32
        }
        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, pos >= 0, pos + n <= end else { throw Issue("read past the end of the structure at offset \(pos)") }
            defer { pos += n }
            return Array(b[pos..<(pos + n)])
        }
        mutating func skip(_ n: Int) throws {
            guard n >= 0, pos + n <= end else { throw Issue("read past the end of the structure at offset \(pos)") }
            pos += n
        }
    }

    // MARK: - Property sets (shared by both layouts)

    /// An object's identity: a GUID from the revision's global id table plus a
    /// 32-bit n (ExtendedGUID), or the raw CompactID when nothing resolves it.
    struct ObjectID: Hashable { let guid: [UInt8]; let n: UInt32 }

    struct ObjectRef { let raw: UInt32; let resolved: ObjectID? }

    struct PropertySet { var entries: [(id: UInt32, value: PropertyValue)] = [] }

    indirect enum PropertyValue {
        case none
        case scalar(UInt64)
        case data(Range<Int>)            // absolute byte range in the file
        case references([ObjectRef])
        case set(PropertySet)
        case array([PropertyValue])
    }

    static let maxPropertySetDepth = 100

    /// ObjectSpaceObjectPropSet (MS-ONESTORE §2.6.1): the OID stream, the
    /// optional OSID and ContextID streams, then the PropertySet body.
    static func parsePropertySet(_ b: [UInt8], start: Int, end: Int, resolve: (UInt32) throws -> ObjectID?) throws -> PropertySet {
        var c = Cursor(b, pos: start, end: end)
        func readStream() throws -> (ids: [ObjectRef], extended: Bool, osidsAbsent: Bool) {
            let header = try c.u32()
            let count = Int(header & 0xFF_FFFF)
            var ids: [ObjectRef] = []
            ids.reserveCapacity(min(count, max(c.remaining / 4, 0)))
            for _ in 0..<count {
                let raw = try c.u32()
                ids.append(ObjectRef(raw: raw, resolved: try resolve(raw)))
            }
            return (ids, (header >> 30) & 1 == 1, (header >> 31) & 1 == 1)
        }
        let oids = try readStream()
        var osids: [ObjectRef] = [], contextIDs: [ObjectRef] = []
        var extended = oids.extended
        if !oids.osidsAbsent {
            let s = try readStream()
            osids = s.ids
            extended = extended || s.extended
        }
        if extended { contextIDs = try readStream().ids }
        var counters = StreamCounters()
        return try parseSet(&c, oids: oids.ids, osids: osids, contextIDs: contextIDs, counters: &counters, depth: 0)
    }

    struct StreamCounters { var oid = 0, osid = 0, context = 0 }

    static func parseSet(_ c: inout Cursor, oids: [ObjectRef], osids: [ObjectRef], contextIDs: [ObjectRef], counters: inout StreamCounters, depth: Int) throws -> PropertySet {
        guard depth < maxPropertySetDepth else { throw Issue("property sets nested more than \(maxPropertySetDepth) deep") }
        let count = Int(try c.u16())
        var ids: [UInt32] = []
        ids.reserveCapacity(min(count, max(c.remaining / 4, 0)))
        for _ in 0..<count { ids.append(try c.u32()) }
        var set = PropertySet()
        for id in ids {
            set.entries.append((id, try parseValue(id: id, &c, oids: oids, osids: osids, contextIDs: contextIDs, counters: &counters, depth: depth)))
        }
        return set
    }

    static func propertyType(_ id: UInt32) -> UInt32 { (id >> 26) & 0x1F }

    static func parseValue(id: UInt32, _ c: inout Cursor, oids: [ObjectRef], osids: [ObjectRef], contextIDs: [ObjectRef], counters: inout StreamCounters, depth: Int) throws -> PropertyValue {
        func take(_ stream: [ObjectRef], _ counter: inout Int, _ n: Int, _ what: String) throws -> [ObjectRef] {
            guard n >= 0, counter + n <= stream.count else { throw Issue("\(what) references run past the stream") }
            defer { counter += n }
            return Array(stream[counter..<(counter + n)])
        }
        switch propertyType(id) {
        case 0x1: return .none
        case 0x2: return .scalar(UInt64(id >> 31))
        case 0x3: return .scalar(UInt64(try c.u8()))
        case 0x4: return .scalar(UInt64(try c.u16()))
        case 0x5: return .scalar(UInt64(try c.u32()))
        case 0x6: return .scalar(try c.u64())
        case 0x7:
            let length = Int(try c.u32())
            guard length >= 0, length <= c.remaining else { throw Issue("property data (\(length) bytes) runs past the object") }
            let range = c.pos..<(c.pos + length)
            c.pos += length
            return .data(range)
        case 0x8: return .references(try take(oids, &counters.oid, 1, "object"))
        case 0x9: return .references(try take(oids, &counters.oid, Int(try c.u32()), "object"))
        case 0xA: return .references(try take(osids, &counters.osid, 1, "object space"))
        case 0xB: return .references(try take(osids, &counters.osid, Int(try c.u32()), "object space"))
        case 0xC: return .references(try take(contextIDs, &counters.context, 1, "context"))
        case 0xD: return .references(try take(contextIDs, &counters.context, Int(try c.u32()), "context"))
        case 0x10:
            let n = Int(try c.u32())
            let inner = try c.u32()
            // Elements of type 1 or 2 carry no bytes; nothing to read for them.
            guard propertyType(inner) > 2 else { return .array([]) }
            var values: [PropertyValue] = []
            for _ in 0..<n {
                values.append(try parseValue(id: inner, &c, oids: oids, osids: osids, contextIDs: contextIDs, counters: &counters, depth: depth + 1))
            }
            return .array(values)
        case 0x11:
            return .set(try parseSet(&c, oids: oids, osids: osids, contextIDs: contextIDs, counters: &counters, depth: depth + 1))
        default:
            throw Issue("property type \(propertyType(id)) is not defined")
        }
    }

    // MARK: - Text from property values

    /// Collects text runs; each byte range is emitted once however many
    /// objects reference it (Tika's offset/length set).
    final class TextSink {
        let b: [UInt8]
        var lines: [String] = []
        private var seen: Set<Range<Int>> = []
        init(bytes: [UInt8]) { b = bytes }

        /// The lines collected so far; the sink keeps its memory of ranges.
        func drain() -> [String] {
            defer { lines.removeAll() }
            return lines
        }

        func unicode(_ range: Range<Int>) {
            guard seen.insert(range).inserted, range.upperBound <= b.count else { return }
            var endIndex = range.lowerBound
            while endIndex + 1 < range.upperBound {
                if b[endIndex] == 0 && b[endIndex + 1] == 0 { break }
                endIndex += 2
            }
            guard endIndex > range.lowerBound else { return }
            guard let s = String(bytes: b[range.lowerBound..<endIndex], encoding: .utf16LittleEndian) else { return }
            append(s)
        }

        func ascii(_ range: Range<Int>) {
            guard seen.insert(range).inserted, range.upperBound <= b.count else { return }
            let slice = b[range].prefix { $0 != 0 }
            guard let s = String(bytes: slice, encoding: .ascii) else { return }
            append(s)
        }

        private func append(_ raw: String) {
            let text = hyperlink(raw) ?? raw
            for piece in text.replacingOccurrences(of: "\u{000B}", with: "\n").split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(piece).unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" }.map { Character($0) }
                let cleaned = String(line).trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { lines.append(cleaned) }
            }
        }

        /// A rich-text field of the form U+FDDF HYPERLINK "url"label → "label <url>".
        private func hyperlink(_ s: String) -> String? {
            // U+FDDF (a noncharacter Swift literals cannot spell) marks a field code.
            guard let marker = s.unicodeScalars.first, marker.value == 0xFDDF else { return nil }
            let body = String(String.UnicodeScalarView(s.unicodeScalars.dropFirst()))
            guard body.hasPrefix("HYPERLINK") else { return nil }
            let rest = body.dropFirst("HYPERLINK".count).drop(while: { $0 == " " || $0 == "\t" })
            guard rest.first == "\"" else { return nil }
            let afterQuote = rest.dropFirst()
            guard let close = afterQuote.firstIndex(of: "\"") else { return nil }
            let url = String(afterQuote[..<close])
            let label = String(afterQuote[afterQuote.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return nil }
            return label.isEmpty ? url : "\(label) <\(url)>"
        }
    }

    /// Emits the text properties of one set; children are left to the caller.
    static func emitText(of set: PropertySet, parentProperty: UInt32?, into sink: TextSink, child: (ObjectID, UInt32) -> Void) {
        for entry in set.entries { emitText(id: entry.id, value: entry.value, parentProperty: parentProperty, into: sink, child: child) }
    }

    static func emitText(id: UInt32, value: PropertyValue, parentProperty: UInt32?, into sink: TextSink, child: (ObjectID, UInt32) -> Void) {
        switch value {
        case .data(let range):
            if id == richEditTextUnicode || id == cachedTitleString {
                if parentProperty != elementChildNodesOfVersionHistory { sink.unicode(range) }
            } else if id == textExtendedAscii {
                sink.ascii(range)
            }
        case .references(let refs):
            for ref in refs { if let resolved = ref.resolved { child(resolved, id) } }
        case .set(let inner):
            emitText(of: inner, parentProperty: parentProperty, into: sink, child: child)
        case .array(let values):
            for v in values { emitText(id: id, value: v, parentProperty: parentProperty, into: sink, child: child) }
        case .none, .scalar:
            break
        }
    }

    // MARK: - Fallback: strings scan

    /// GNU-strings style recovery (Tika's legacy dump): ASCII runs and UTF-16LE
    /// runs of at least 8 characters that contain a space and are mostly letters.
    static func recoveredStrings(_ b: [UInt8]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func consider(_ s: String) {
            guard s.count >= 8, s.contains(" ") else { return }
            let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.whitespaces.contains($0) }.count
            guard Double(letters) / Double(s.unicodeScalars.count) > 0.6 else { return }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if seen.insert(trimmed).inserted { out.append(trimmed) }
        }
        var run: [UInt8] = []
        for byte in b {
            if byte >= 0x20 && byte < 0x7F { run.append(byte) } else {
                if run.count >= 8, let s = String(bytes: run, encoding: .ascii) { consider(s) }
                run.removeAll(keepingCapacity: true)
            }
        }
        if run.count >= 8, let s = String(bytes: run, encoding: .ascii) { consider(s) }
        var units: [UInt16] = []
        var i = 0
        while i + 1 < b.count {
            let unit = UInt16(b[i]) | UInt16(b[i + 1]) << 8
            if unit >= 0x20 && unit != 0x7F && !(0xD800...0xDFFF).contains(unit) && unit != 0xFFFE && unit != 0xFFFF {
                units.append(unit); i += 2
            } else {
                if units.count >= 8 { consider(String(decoding: units, as: UTF16.self)) }
                units.removeAll(keepingCapacity: true)
                i += 1
            }
        }
        if units.count >= 8 { consider(String(decoding: units, as: UTF16.self)) }
        return out
    }

    static func guidString(_ g: [UInt8]) -> String {
        guard g.count == 16 else { return "{?}" }
        let h = g.map { String(format: "%02X", $0) }
        return "{\(h[3])\(h[2])\(h[1])\(h[0])-\(h[5])\(h[4])-\(h[7])\(h[6])-\(h[8])\(h[9])-\(h[10])\(h[11])\(h[12])\(h[13])\(h[14])\(h[15])}"
    }
}

// MARK: - MS-ONESTORE revision store

extension OneNoteTextExtractor {

    final class OneStoreFile {
        static let fragmentMagic: UInt64 = 0xA456_7AB1_F5F7_F4C4
        static let fragmentFooter: UInt64 = 0x8BC2_15C3_8233_BA4B
        static let maxListDepth = 100
        static let maxWalkDepth = 500

        struct ChunkRef {
            let stp: Int
            let cb: Int
            var isNil: Bool { stp < 0 || (stp == 0 && cb == 0) }
            var end: Int { stp + cb }
        }

        final class Node {
            let id: Int
            let baseType: Int
            var ref: ChunkRef?
            var gosid: ObjectID?
            var rootRole: UInt32?
            var children: [Node] = []
            var propertySet: PropertySet?
            init(id: Int, baseType: Int) { self.id = id; self.baseType = baseType }
        }

        struct Revision { var globalId: [UInt32: [UInt8]] = [:]; var dependent: ObjectID? }
        struct Role: Equatable { let role: UInt32; let context: ObjectID? }

        let b: [UInt8]
        var root: [Node] = []
        var revisions: [ObjectID: Revision] = [:]
        var currentRevision: ObjectID?
        var revisionRoles: [ObjectID: Role] = [:]
        var revisionLists: [(gosid: ObjectID, list: Node)] = []
        /// The newest declaration of each object (what a page's walk follows).
        var objects: [ObjectID: Node] = [:]
        /// Every declaration in file order — an object re-declared by a later
        /// revision keeps its earlier content here, as Tika's full crawl does.
        var declarations: [Node] = []
        var issues: [String] = []
        var encrypted = false
        var embeddedFiles: [Int] = []
        var depthLimitHit = false
        private var listDepth = 0
        private var activeLists: Set<Int> = []

        init(bytes: [UInt8]) { b = bytes }

        // MARK: Parse

        func parse() {
            guard b.count >= 184 else { issues.append("header is shorter than 184 bytes"); return }
            var c = Cursor(b, pos: 172, end: b.count)
            do {
                let stp = try c.u64(), cb = try c.u32()
                let ref = ChunkRef(stp: Int(Int64(bitPattern: stp)), cb: Int(cb))
                guard !ref.isNil else { issues.append("the header names no root file node list"); return }
                root = parseList(ref)
            } catch let issue as Issue { issues.append(issue.text) } catch { issues.append(String(describing: error)) }
        }

        func parseList(_ ref: ChunkRef) -> [Node] {
            var nodes: [Node] = []
            do { try parseFragments(ref, into: &nodes) } catch let issue as Issue { issues.append(issue.text) } catch { issues.append(String(describing: error)) }
            return nodes
        }

        private func parseFragments(_ first: ChunkRef, into nodes: inout [Node]) throws {
            guard listDepth < Self.maxListDepth else { throw Issue("file node lists nested more than \(Self.maxListDepth) deep") }
            guard activeLists.insert(first.stp).inserted else { throw Issue("file node list cycle at offset \(first.stp)") }
            listDepth += 1
            defer { listDepth -= 1; activeLists.remove(first.stp) }
            var current = first
            var seenFragments: Set<Int> = [first.stp]
            while true {
                guard current.stp >= 0, current.cb >= 36, current.end <= b.count else {
                    throw Issue("file node list fragment at offset \(current.stp) (\(current.cb) bytes) lies outside the file")
                }
                var c = Cursor(b, pos: current.stp, end: current.end)
                guard try c.u64() == Self.fragmentMagic else { throw Issue("file node list fragment at offset \(current.stp) has no header") }
                _ = try c.u32(); _ = try c.u32()
                while c.pos + 24 <= current.end {
                    let start = c.pos
                    guard let node = try parseNode(&c) else { break }
                    nodes.append(node)
                    if c.pos == start { break }
                }
                var tail = Cursor(b, pos: current.end - 20, end: current.end)
                let nextStp = try tail.u64(), nextCb = try tail.u32()
                guard try tail.u64() == Self.fragmentFooter else { throw Issue("file node list fragment at offset \(current.stp) has no footer") }
                let next = ChunkRef(stp: Int(Int64(bitPattern: nextStp)), cb: Int(nextCb))
                if next.isNil { break }
                guard seenFragments.insert(next.stp).inserted else { throw Issue("file node list fragment cycle at offset \(next.stp)") }
                current = next
            }
        }

        private func readRef(_ c: inout Cursor, stpFormat: UInt32, cbFormat: UInt32) throws -> ChunkRef {
            let stp: Int
            switch stpFormat {
            case 0: stp = Int(Int64(bitPattern: try c.u64()))
            case 1: stp = Int(try c.u32())
            case 2: stp = Int(try c.u16()) << 3
            default: stp = Int(try c.u32()) << 3
            }
            let cb: Int
            switch cbFormat {
            case 0: cb = Int(try c.u32())
            case 1: cb = Int(Int64(bitPattern: try c.u64()))
            case 2: cb = Int(try c.u8()) << 3
            default: cb = Int(try c.u16()) << 3
            }
            return ChunkRef(stp: stp, cb: cb)
        }

        private func extendedGUID(_ c: inout Cursor) throws -> ObjectID {
            ObjectID(guid: try c.bytes(16), n: try c.u32())
        }

        private func compactID(_ c: inout Cursor) throws -> ObjectID {
            let raw = try c.u32()
            return try resolve(raw)
        }

        private func resolve(_ raw: UInt32) throws -> ObjectID {
            let index = raw >> 8
            guard let current = currentRevision, let guid = revisions[current]?.globalId[index] else {
                throw Issue("compact id \(index) is not in the current revision's global id table")
            }
            return ObjectID(guid: guid, n: raw & 0xFF)
        }

        private func currentRevisionValue() throws -> Revision {
            guard let current = currentRevision, let revision = revisions[current] else { throw Issue("no current revision") }
            return revision
        }

        private func dependentRevision() throws -> Revision {
            let current = try currentRevisionValue()
            guard let dependent = current.dependent, let revision = revisions[dependent] else { throw Issue("missing dependent revision") }
            return revision
        }

        private func registerRevision(_ rid: ObjectID, dependent: ObjectID) {
            var revision = revisions[rid] ?? Revision()
            revision.dependent = dependent
            revisions[rid] = revision
            currentRevision = rid
        }

        /// One FileNode (MS-ONESTORE §2.4.3); nil for a terminator.
        private func parseNode(_ c: inout Cursor) throws -> Node? {
            let start = c.pos
            let header = try c.u32()
            let id = Int(header & 0x3FF)
            if id == 0 || id == 0xFF { return nil }
            let size = Int((header >> 10) & 0x1FFF)
            let stpFormat = (header >> 23) & 3, cbFormat = (header >> 25) & 3
            let baseType = Int((header >> 27) & 0xF)
            guard header >> 31 == 1 else { throw Issue("file node at offset \(start) has a cleared reserved bit") }
            guard size >= 4, start + size <= c.end else { throw Issue("file node at offset \(start) (\(size) bytes) runs past its list") }
            var n = Cursor(b, pos: c.pos, end: start + size)
            let node = Node(id: id, baseType: baseType)
            if baseType == 1 || baseType == 2 { node.ref = try readRef(&n, stpFormat: stpFormat, cbFormat: cbFormat) }
            // A node whose data cannot be read (a CompactID outside the global
            // id table, a truncated field) is recorded and skipped; the node's
            // size still says where the next one starts, so the rest of the
            // list is read.
            do { try parseNodeData(node, &n) } catch let issue as Issue { issues.append("file node \(String(id, radix: 16)) at offset \(start): \(issue.text)") }

            if baseType == 2, let ref = node.ref, !ref.isNil {
                node.children = parseList(ref)
                if id == 0x10 {
                    for child in node.children where child.id == 0x14 {
                        if let gosid = child.gosid { revisionLists.append((gosid, node)) }
                    }
                }
            }
            c.pos = start + size
            return node
        }

        private func parseNodeData(_ node: Node, _ n: inout Cursor) throws {
            let id = node.id
            switch id {
            case 0x04, 0x08, 0x0C, 0x14, 0x8C, 0xB0, 0xB4:
                node.gosid = try extendedGUID(&n)
            case 0x1B:
                let rid = try extendedGUID(&n), dependent = try extendedGUID(&n)
                _ = try n.u64(); _ = try n.u32(); _ = try n.u16()
                node.gosid = rid
                registerRevision(rid, dependent: dependent)
            case 0x1E, 0x1F:
                let rid = try extendedGUID(&n), dependent = try extendedGUID(&n)
                let role = try n.u32(); _ = try n.u16()
                let context: ObjectID? = id == 0x1F ? try extendedGUID(&n) : nil
                node.gosid = rid
                revisionRoles[rid] = Role(role: role, context: context)
                registerRevision(rid, dependent: dependent)
            case 0x21:
                _ = try n.u8()
            case 0x24:
                let index = try n.u32(), guid = try n.bytes(16)
                guard let current = currentRevision, revisions[current] != nil else { throw Issue("global id table entry outside a revision") }
                revisions[current]?.globalId[index] = guid
            case 0x25:
                let from = try n.u32(), to = try n.u32()
                let dependent = try dependentRevision()
                guard let guid = dependent.globalId[from], let current = currentRevision else { throw Issue("global id table entry \(from) is missing from the dependent revision") }
                revisions[current]?.globalId[to] = guid
            case 0x26:
                let from = try n.u32(), count = try n.u32(), to = try n.u32()
                let dependent = try dependentRevision()
                guard let current = currentRevision else { throw Issue("no current revision") }
                var i: UInt32 = 0
                while i < count {
                    guard let guid = dependent.globalId[from &+ i] else { throw Issue("global id table entry \(from &+ i) is missing from the dependent revision") }
                    revisions[current]?.globalId[to &+ i] = guid
                    i += 1
                }
            case 0x2D, 0x2E:
                let oid = try compactID(&n)
                let jci = try n.u32(); _ = try n.u16()
                if id == 0x2D { _ = try n.u8() } else { _ = try n.u32() }
                declareObject(node, oid: oid, isPropertySet: (jci & 0x3FF) > 0)
            case 0xA4, 0xA5, 0xC4, 0xC5:
                let oid = try compactID(&n)
                let jcid = try n.u32(); _ = try n.u8()
                if id == 0xA4 || id == 0xC4 { _ = try n.u8() } else { _ = try n.u32() }
                if id == 0xC4 || id == 0xC5 { _ = try n.bytes(16) }
                let isBinary = (jcid >> 16) & 1 == 1, isPropertySet = (jcid >> 17) & 1 == 1, isGraphNode = (jcid >> 18) & 1 == 1
                let isFileData = (jcid >> 19) & 1 == 1, isReadOnly = (jcid >> 20) & 1 == 1
                let propSet = isPropertySet || (!isBinary && !isGraphNode && !isFileData && !isReadOnly && (jcid & 0xFFFF) > 0)
                declareObject(node, oid: oid, isPropertySet: propSet)
            case 0x72, 0x73:
                _ = try compactID(&n); _ = try n.u32()
                if id == 0x72 { _ = try n.u8() } else { _ = try n.u32() }
                let cch = Int(try n.u32())
                _ = try n.bytes(cch * 2)     // an external file reference; nothing read from it
            case 0x41:
                _ = try compactID(&n); _ = try n.u8()
            case 0x42:
                _ = try compactID(&n); _ = try n.u32(); _ = try n.u32()
            case 0x59:
                node.gosid = try compactID(&n)
                node.rootRole = try n.u32()
            case 0x5A:
                node.gosid = try extendedGUID(&n)
                node.rootRole = try n.u32()
            case 0x5C, 0x5D:
                let rid = try extendedGUID(&n), role = try n.u32()
                let context: ObjectID? = id == 0x5D ? try extendedGUID(&n) : nil
                revisionRoles[rid] = Role(role: role, context: context)
            case 0x7C:
                encrypted = true
            case 0x94:
                _ = try n.bytes(16)                                   // guidReference
                if let ref = node.ref, !ref.isNil, ref.stp + 40 <= b.count {
                    var f = Cursor(b, pos: ref.stp + 16, end: b.count)
                    let length = try f.u64()
                    embeddedFiles.append(Int(clamping: length))
                }
            default:
                break
            }
        }

        private func declareObject(_ node: Node, oid: ObjectID, isPropertySet: Bool) {
            node.gosid = oid
            declarations.append(node)
            objects[oid] = node
            guard isPropertySet, let ref = node.ref, !ref.isNil else { return }
            guard ref.stp >= 0, ref.cb >= 0, ref.end <= b.count else {
                issues.append("object at offset \(ref.stp) (\(ref.cb) bytes) lies outside the file"); return
            }
            do {
                node.propertySet = try OneNoteTextExtractor.parsePropertySet(b, start: ref.stp, end: ref.end) { try self.resolve($0) }
            } catch let issue as Issue { issues.append("object at offset \(ref.stp): \(issue.text)") } catch { issues.append(String(describing: error)) }
        }

        // MARK: Walk

        /// The text of every object space: the latest revision with role 1,
        /// its root object (root role 1) and the objects it references — then,
        /// as Tika does, the text of every other object in the file (earlier
        /// revisions, objects no current page reaches), each run once.
        func collectText() -> (pages: [[String]], otherObjects: [String]) {
            var pages: [[String]] = []
            let wanted = Role(role: 1, context: nil)
            let sink = TextSink(bytes: b)
            for (_, list) in revisionLists {
                var valid: ObjectID?
                for child in list.children.reversed() where isRevisionStart(child.id) {
                    if let g = child.gosid, revisionRoles[g] == wanted { valid = g; break }
                }
                var inValidRevision = false
                for child in list.children {
                    if isRevisionStart(child.id) { inValidRevision = child.gosid == valid && valid != nil }
                    guard inValidRevision, child.id == 0x59 || child.id == 0x5A, child.rootRole == 1, let root = child.gosid else { continue }
                    var active: Set<ObjectIdentifier> = []
                    walk(root, parentProperty: nil, depth: 0, active: &active, sink: sink)
                }
                let lines = sink.drain()
                if !lines.isEmpty { pages.append(lines) }
            }
            for node in declarations {
                guard let set = node.propertySet else { continue }
                OneNoteTextExtractor.emitText(of: set, parentProperty: nil, into: sink) { _, _ in }
            }
            return (pages, sink.drain())
        }

        private func isRevisionStart(_ id: Int) -> Bool { id == 0x1B || id == 0x1E || id == 0x1F }

        private func walk(_ oid: ObjectID, parentProperty: UInt32?, depth: Int, active: inout Set<ObjectIdentifier>, sink: TextSink) {
            guard depth < Self.maxWalkDepth else { depthLimitHit = true; return }
            guard let node = objects[oid], let set = node.propertySet else { return }
            let key = ObjectIdentifier(node)
            guard active.insert(key).inserted else { return }
            defer { active.remove(key) }
            var pending: [(ObjectID, UInt32)] = []
            OneNoteTextExtractor.emitText(of: set, parentProperty: parentProperty, into: sink) { child, property in pending.append((child, property)) }
            for (child, property) in pending { walk(child, parentProperty: property, depth: depth + 1, active: &active, sink: sink) }
        }
    }
}

// MARK: - FSSHTTPB alternative packaging

extension OneNoteTextExtractor {

    final class PackagedStore {
        struct ExGuid: Hashable { let guid: [UInt8]; let value: UInt32 }
        /// Root ExGUID {4A3717F8-1C14-49E7-9526-81D942DE1741}:3 — the encryption key of a protected section.
        static let encryptionKeyRoot = ExGuid(guid: [0xF8, 0x17, 0x37, 0x4A, 0x14, 0x1C, 0xE7, 0x49, 0x95, 0x26, 0x81, 0xD9, 0x42, 0xDE, 0x17, 0x41], value: 3)

        enum Header { case start(type: Int, length: Int, compound: Bool), end(type: Int) }

        struct Entry { let id: ExGuid; var propertySet: Range<Int>? }

        let b: [UInt8]
        var issues: [String] = []
        var encrypted = false
        var embeddedFiles: [Int] = []
        private var order: [ExGuid] = []
        private var entries: [ExGuid: Entry] = [:]

        init(bytes: [UInt8]) { b = bytes }

        func parse() {
            do { try parseAll() } catch let issue as Issue { issues.append(issue.text) } catch { issues.append(String(describing: error)) }
        }

        private func parseAll() throws {
            var c = Cursor(b, pos: 64, end: b.count)
            _ = try c.u32()                                           // rgbReserved
            guard case .start(0x7A, _, _) = try header(&c) else { throw Issue("no alternative packaging header after the file GUIDs") }
            _ = try exGuid(&c)                                        // storage index
            try c.skip(16)                                            // cell schema GUID
            guard case .start(0x15, let length, _) = try header(&c), length == 1 else { throw Issue("no data element package") }
            _ = try c.u8()                                            // reserved
            while c.pos < c.end {
                switch try header(&c) {
                case .end(let type):
                    guard type == 0x15 else { throw Issue("unexpected end marker \(type) in the data element package") }
                    return
                case .start(0x01, let length, _):
                    try parseDataElement(&c, itemsLength: length)
                case .start(let type, let length, let compound):
                    try c.skip(length)
                    if compound { try skipUntilEnd(&c, of: type) }
                }
            }
        }

        private func parseDataElement(_ c: inout Cursor, itemsLength: Int) throws {
            let itemsEnd = c.pos + itemsLength
            _ = try exGuid(&c)
            try serialNumber(&c)
            let type = try compactUInt(&c)
            guard c.pos <= itemsEnd, itemsEnd <= c.end else { throw Issue("data element header runs past its length") }
            c.pos = itemsEnd
            var declares: [(id: ExGuid, partition: UInt64)] = []
            var datas: [Range<Int>] = []
            while c.pos < c.end {
                switch try header(&c) {
                case .end(let t):
                    guard t == 0x01 else { throw Issue("unexpected end marker \(t) in a data element") }
                    if type == 5 { pair(declares, datas) }
                    return
                case .start(let t, let length, let compound):
                    switch (type, t) {
                    case (5, 0x1D):                                   // object group declarations
                        try c.skip(length)
                        try parseDeclarations(&c, into: &declares)
                    case (5, 0x1E):                                   // object group data
                        try c.skip(length)
                        try parseObjectData(&c, into: &datas)
                    case (4, 0x0A):                                   // revision manifest root declare
                        let end = c.pos + length
                        let root = try exGuid(&c)
                        if root == Self.encryptionKeyRoot { encrypted = true }
                        c.pos = end
                    default:
                        try c.skip(length)
                        if compound { try skipUntilEnd(&c, of: t) }
                    }
                }
            }
            throw Issue("data element is not closed")
        }

        private func parseDeclarations(_ c: inout Cursor, into declares: inout [(id: ExGuid, partition: UInt64)]) throws {
            while c.pos < c.end {
                switch try header(&c) {
                case .end(let t):
                    guard t == 0x1D else { throw Issue("unexpected end marker \(t) in object group declarations") }
                    return
                case .start(0x18, let length, _):
                    let end = c.pos + length
                    let id = try exGuid(&c)
                    let partition = try compactUInt(&c)
                    declares.append((id, partition))
                    c.pos = end
                case .start(0x05, let length, _):
                    let end = c.pos + length
                    _ = try exGuid(&c); _ = try exGuid(&c)
                    let partition = try compactUInt(&c)
                    let size = try compactUInt(&c)
                    if partition == 2 { embeddedFiles.append(Int(clamping: size)) }
                    c.pos = end
                case .start(let t, let length, let compound):
                    try c.skip(length)
                    if compound { try skipUntilEnd(&c, of: t) }
                }
            }
            throw Issue("object group declarations are not closed")
        }

        private func parseObjectData(_ c: inout Cursor, into datas: inout [Range<Int>]) throws {
            while c.pos < c.end {
                switch try header(&c) {
                case .end(let t):
                    guard t == 0x1E else { throw Issue("unexpected end marker \(t) in object group data") }
                    return
                case .start(0x16, let length, _):
                    let end = c.pos + length
                    let referenceCount = try compactUInt(&c)
                    var i: UInt64 = 0
                    while i < referenceCount { _ = try exGuid(&c); i += 1 }
                    let cellCount = try compactUInt(&c)
                    i = 0
                    while i < cellCount { _ = try exGuid(&c); _ = try exGuid(&c); i += 1 }
                    let size = Int(clamping: try compactUInt(&c))
                    guard size <= c.remaining, c.pos + size <= end else { throw Issue("object data (\(size) bytes) runs past its element") }
                    datas.append(c.pos..<(c.pos + size))
                    c.pos = end
                case .start(let t, let length, let compound):
                    try c.skip(length)
                    if compound { try skipUntilEnd(&c, of: t) }
                }
            }
            throw Issue("object group data is not closed")
        }

        /// Declaration i pairs with object data i; partition 1 is the property set.
        private func pair(_ declares: [(id: ExGuid, partition: UInt64)], _ datas: [Range<Int>]) {
            for (index, declare) in declares.enumerated() where index < datas.count && declare.partition == 1 {
                if entries[declare.id] == nil { order.append(declare.id) }
                entries[declare.id] = Entry(id: declare.id, propertySet: datas[index])   // the newest revision wins
            }
        }

        private func skipUntilEnd(_ c: inout Cursor, of type: Int) throws {
            while c.pos < c.end {
                switch try header(&c) {
                case .end(let t):
                    guard t == type else { throw Issue("end marker \(t) does not close stream object \(type)") }
                    return
                case .start(let t, let length, let compound):
                    try c.skip(length)
                    if compound { try skipUntilEnd(&c, of: t) }
                }
            }
            throw Issue("stream object \(type) is not closed")
        }

        // MARK: Basic encodings (MS-FSSHTTPB §2.2.1)

        private func header(_ c: inout Cursor) throws -> Header {
            let b0 = try c.u8()
            switch b0 & 3 {
            case 0:
                let v = UInt32(b0) | UInt32(try c.u8()) << 8
                return .start(type: Int((v >> 3) & 0x3F), length: Int((v >> 9) & 0x7F), compound: (v >> 2) & 1 == 1)
            case 2:
                let v = UInt32(b0) | UInt32(try c.u8()) << 8 | UInt32(try c.u8()) << 16 | UInt32(try c.u8()) << 24
                var length = Int((v >> 17) & 0x7FFF)
                if length == 32767 { length = Int(clamping: try compactUInt(&c)) }
                return .start(type: Int((v >> 3) & 0x3FFF), length: length, compound: (v >> 2) & 1 == 1)
            case 1:
                return .end(type: Int(b0 >> 2))
            default:
                let v = UInt32(b0) | UInt32(try c.u8()) << 8
                return .end(type: Int((v >> 2) & 0x3FFF))
            }
        }

        private func compactUInt(_ c: inout Cursor) throws -> UInt64 {
            let b0 = try c.u8()
            if b0 == 0 { return 0 }
            let zeros = b0.trailingZeroBitCount
            if zeros == 7 { return try c.u64() }
            var value = UInt64(b0 >> UInt8(zeros + 1))
            var shift = 7 - zeros
            for _ in 0..<zeros {
                value |= UInt64(try c.u8()) << UInt64(shift)
                shift += 8
            }
            return value
        }

        private func exGuid(_ c: inout Cursor) throws -> ExGuid {
            let b0 = try c.u8()
            if b0 == 0 { return ExGuid(guid: [UInt8](repeating: 0, count: 16), value: 0) }
            if b0 & 0x07 == 0x04 { return ExGuid(guid: try c.bytes(16), value: UInt32(b0 >> 3)) }
            if b0 & 0x3F == 0x20 {
                let b1 = try c.u8()
                return ExGuid(guid: try c.bytes(16), value: UInt32(b0 >> 6) | UInt32(b1) << 2)
            }
            if b0 & 0x7F == 0x40 {
                let b1 = try c.u8(), b2 = try c.u8()
                return ExGuid(guid: try c.bytes(16), value: UInt32(b0 >> 7) | UInt32(b1) << 1 | UInt32(b2) << 9)
            }
            if b0 == 0x80 {
                let value = try c.u32()
                return ExGuid(guid: try c.bytes(16), value: value)
            }
            throw Issue("extended GUID with undefined type byte \(b0)")
        }

        private func serialNumber(_ c: inout Cursor) throws {
            let type = try c.u8()
            if type == 0 { return }
            guard type == 128 else { throw Issue("serial number with undefined type \(type)") }
            try c.skip(24)
        }

        // MARK: Text

        func collectText() -> [String] {
            let sink = TextSink(bytes: b)
            for id in order {
                guard let range = entries[id]?.propertySet else { continue }
                do {
                    let set = try OneNoteTextExtractor.parsePropertySet(b, start: range.lowerBound, end: range.upperBound) { _ in nil }
                    OneNoteTextExtractor.emitText(of: set, parentProperty: nil, into: sink) { _, _ in }
                } catch let issue as Issue {
                    issues.append("object at offset \(range.lowerBound): \(issue.text)")
                } catch { issues.append(String(describing: error)) }
            }
            return sink.lines
        }
    }
}
