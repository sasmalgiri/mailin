@testable import ArchiveCore
//
//  PreservationExporter.swift
//  maxmailin
//
//  §3-E5 (switch: `v3PreservationExport`). A preservation package in the
//  archival standard libraries and archives use (BagIt, RFC 8493) with
//  PREMIS 3 preservation metadata — the format ePADD produces.
//
//  Layout:
//    <bag>/bagit.txt
//    <bag>/bag-info.txt                 Source-Organization, Bagging-Date, Payload-Oxum …
//    <bag>/data/originals/<id>.eml      exact stored raw MIME bytes
//    <bag>/data/metadata/premis.xml     one PREMIS object per file (SHA-256 fixity,
//                                       size, format) + ingestion/fixity events + agent
//    <bag>/manifest-sha256.txt          every payload file
//    <bag>/tagmanifest-sha256.txt       every tag file
//
//  Streamed: one email at a time, hashes computed while writing; nothing is
//  held in memory beyond one message. Emails stored without raw MIME are
//  listed (premis event "noOriginalAvailable") and counted, never faked.
//  The bag is verified after writing: every manifest line is re-hashed.
//

import Foundation
import CryptoKit

@MainActor
enum PreservationExporter {
    struct Result {
        var bag: URL
        var originals: Int
        var withoutOriginal: Int
        var payloadBytes: Int64
        var verified: Bool
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func export(scope: ArchiveScope, to bag: URL, organization: String) async throws -> Result {
        let fm = FileManager.default
        let token = EngineGuard.begin(.v3PreservationExport)
        defer { EngineGuard.end(token) }
        let originalsDir = bag.appendingPathComponent("data/originals", isDirectory: true)
        let metadataDir = bag.appendingPathComponent("data/metadata", isDirectory: true)
        try fm.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: metadataDir, withIntermediateDirectories: true)

        let manifestURL = bag.appendingPathComponent("manifest-sha256.txt")
        fm.createFile(atPath: manifestURL.path, contents: nil)
        let manifest = try FileHandle(forWritingTo: manifestURL)
        defer { try? manifest.close() }
        let premisURL = metadataDir.appendingPathComponent("premis.xml")
        fm.createFile(atPath: premisURL.path, contents: nil)
        let premis = try FileHandle(forWritingTo: premisURL)
        defer { try? premis.close() }

        let now = ISO8601DateFormatter().string(from: Date())
        let agent = "mailin \(EngineGuard.appVersion)"
        try premis.write(contentsOf: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <premis xmlns="http://www.loc.gov/premis/v3" version="3.0">
            <agent><agentIdentifier><agentIdentifierType>local</agentIdentifierType><agentIdentifierValue>\(xmlEscape(agent))</agentIdentifierValue></agentIdentifier><agentName>\(xmlEscape(agent))</agentName><agentType>software</agentType></agent>

            """.utf8))

        var originals = 0, missing = 0
        var bytes: Int64 = 0
        let store = SQLiteEmailStore.shared
        for try await page in ArchiveDataService.shared.streamSummaries(query: scope.query, batchSize: 500) {
            try Task.checkCancellation()
            for summary in page {
                let id = summary.id.uuidString
                guard let raw = try? await store.rawBytes(id: summary.id) else {
                    missing += 1
                    try premis.write(contentsOf: Data("""
                        <event><eventIdentifier><eventIdentifierType>local</eventIdentifierType><eventIdentifierValue>missing-\(id)</eventIdentifierValue></eventIdentifier><eventType>noOriginalAvailable</eventType><eventDateTime>\(now)</eventDateTime><eventDetailInformation><eventDetail>Email \(id) was stored without its original MIME; no preservation copy was made.</eventDetail></eventDetailInformation></event>

                        """.utf8))
                    continue
                }
                let relative = "data/originals/\(id).eml"
                try raw.write(to: bag.appendingPathComponent(relative), options: .atomic)
                let digest = sha256Hex(raw)
                try manifest.write(contentsOf: Data("\(digest)  \(relative)\n".utf8))
                try premis.write(contentsOf: Data("""
                    <object xsi:type="file" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><objectIdentifier><objectIdentifierType>local</objectIdentifierType><objectIdentifierValue>\(id)</objectIdentifierValue></objectIdentifier><objectCharacteristics><compositionLevel>0</compositionLevel><fixity><messageDigestAlgorithm>SHA-256</messageDigestAlgorithm><messageDigest>\(digest)</messageDigest></fixity><size>\(raw.count)</size><format><formatDesignation><formatName>message/rfc822</formatName></formatDesignation></format></objectCharacteristics><originalName>\(xmlEscape(relative))</originalName></object>

                    """.utf8))
                originals += 1
                bytes += Int64(raw.count)
            }
        }
        try premis.write(contentsOf: Data("""
            <event><eventIdentifier><eventIdentifierType>local</eventIdentifierType><eventIdentifierValue>ingest-\(now)</eventIdentifierValue></eventIdentifier><eventType>ingestion</eventType><eventDateTime>\(now)</eventDateTime><eventDetailInformation><eventDetail>\(originals) originals packaged; \(missing) without an original. Scope: \(xmlEscape(scope.description)).</eventDetail></eventDetailInformation><linkingAgentIdentifier><linkingAgentIdentifierType>local</linkingAgentIdentifierType><linkingAgentIdentifierValue>\(xmlEscape(agent))</linkingAgentIdentifierValue></linkingAgentIdentifier></event>
            </premis>

            """.utf8))
        try premis.synchronize()
        try manifest.synchronize()
        try? premis.close()

        // PREMIS is itself a payload file.
        let premisData = try Data(contentsOf: premisURL)
        try manifest.write(contentsOf: Data("\(sha256Hex(premisData))  data/metadata/premis.xml\n".utf8))
        try? manifest.close()

        let bagit = "BagIt-Version: 1.0\nTag-File-Character-Encoding: UTF-8\n"
        try Data(bagit.utf8).write(to: bag.appendingPathComponent("bagit.txt"))
        let payloadBytes = bytes + Int64(premisData.count)
        let info = """
            Source-Organization: \(organization.isEmpty ? "—" : organization)
            Bagging-Date: \(String(now.prefix(10)))
            Bag-Software-Agent: \(agent)
            Payload-Oxum: \(payloadBytes).\(originals + 1)
            External-Description: Email preservation package — \(originals) original messages (message/rfc822) with PREMIS 3 metadata; \(missing) emails had no stored original.

            """
        try Data(info.utf8).write(to: bag.appendingPathComponent("bag-info.txt"))
        var tag = ""
        for name in ["bagit.txt", "bag-info.txt", "manifest-sha256.txt"] {
            tag += "\(sha256Hex(try Data(contentsOf: bag.appendingPathComponent(name))))  \(name)\n"
        }
        try Data(tag.utf8).write(to: bag.appendingPathComponent("tagmanifest-sha256.txt"))

        let verified = try verify(bag: bag)
        ForensicManager.shared.logAction("Preservation package exported",
            detail: "\(originals) originals, \(missing) without an original, bag verified: \(verified) → \(bag.lastPathComponent)")
        return Result(bag: bag, originals: originals, withoutOriginal: missing, payloadBytes: payloadBytes, verified: verified)
    }

    /// Re-hashes every file listed in both manifests (one file at a time).
    static func verify(bag: URL) throws -> Bool {
        for manifestName in ["manifest-sha256.txt", "tagmanifest-sha256.txt"] {
            let text = try String(contentsOf: bag.appendingPathComponent(manifestName), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return false }
                let path = parts[1].trimmingCharacters(in: .whitespaces)
                guard let data = try? Data(contentsOf: bag.appendingPathComponent(path)),
                      sha256Hex(data) == parts[0] else { return false }
            }
        }
        return true
    }
}
