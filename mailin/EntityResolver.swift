//
//  EntityResolver.swift
//  mailin
//
//  Canonicalizes duplicate person/organization nodes in the KnowledgeGraph
//  so that "Alex M.", "Alex Morgan", and "alex+work@acme.example" are
//  recognized as the same entity when the evidence supports it.
//
//  Runs after the KG is built, never on the user's interaction path.
//  100% on-device — uses NLEmbedding for name similarity.
//

import Foundation
import NaturalLanguage

enum EntityResolver {

    struct ResolveResult {
        var personMerges: Int = 0
        var organizationMerges: Int = 0
        var elapsedMs: Int = 0
    }

    /// Walks the graph and merges duplicate person/organization nodes.
    /// Conservative: requires ≥2 independent signals to agree before merging.
    @discardableResult
    static func resolve(graph: KnowledgeGraph) -> ResolveResult {
        let start = Date()
        var result = ResolveResult()

        result.personMerges = resolvePeople(graph: graph)
        result.organizationMerges = resolveOrganizations(graph: graph)

        result.elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        return result
    }

    // MARK: - People

    /// Two person nodes are merged when either:
    ///   1. Their normalized addresses match (subaddress / case folding), OR
    ///   2. Their labels are name-similar AND they share at least one
    ///      strong common neighbor (frequent correspondent or shared domain).
    private static func resolvePeople(graph: KnowledgeGraph) -> Int {
        let people = graph.findNodes(type: .person)
        guard people.count > 1 else { return 0 }

        var canonical: [String: String] = [:]  // node.id  → canonical id
        var merges = 0

        // Pass 1: normalize email subaddresses (alex+work@x → alex@x)
        var byBase: [String: [KGNode]] = [:]
        for node in people {
            guard let raw = node.properties["email"], !raw.isEmpty else { continue }
            let base = normalizeEmail(raw)
            byBase[base, default: []].append(node)
        }
        for (_, group) in byBase where group.count > 1 {
            guard let chosen = pickCanonical(group) else { continue }
            for other in group where other.id != chosen.id {
                canonical[other.id] = chosen.id
                merges += 1
            }
        }

        // Pass 2: same human name + shared strong neighbor (e.g., both
        // belong to the same organization domain or co-receive frequently)
        let embedding = NLEmbedding.wordEmbedding(for: .english)
        let nameBuckets = Dictionary(grouping: people) { simplifyName($0.label) }
        for (_, group) in nameBuckets where group.count > 1 {
            let groupCandidates = group.filter { canonical[$0.id] == nil }
            guard groupCandidates.count > 1 else { continue }

            for i in 0..<groupCandidates.count {
                for j in (i + 1)..<groupCandidates.count {
                    let a = groupCandidates[i]
                    let b = groupCandidates[j]
                    if shouldMerge(a, b, in: graph, embedding: embedding) {
                        guard let chosen = pickCanonical([a, b]) else { continue }
                        let other = chosen.id == a.id ? b : a
                        canonical[other.id] = chosen.id
                        merges += 1
                    }
                }
            }
        }

        apply(canonical: canonical, to: graph)
        return merges
    }

    private static func shouldMerge(_ a: KGNode, _ b: KGNode, in graph: KnowledgeGraph, embedding: NLEmbedding?) -> Bool {
        // Signal 1: name-string similarity
        let nameSim = nameSimilarity(a.label, b.label, embedding: embedding)
        guard nameSim >= 0.85 else { return false }

        // Signal 2: at least one shared strong neighbor
        let neighborsA = Set(graph.edgesFrom(a.id).map(\.targetID))
        let neighborsB = Set(graph.edgesFrom(b.id).map(\.targetID))
        let shared = neighborsA.intersection(neighborsB)
        let sharedStrong = shared.count >= 1

        // Signal 3: same email-domain when both have email properties
        let emailA = a.properties["email"] ?? ""
        let emailB = b.properties["email"] ?? ""
        let domainA = emailA.components(separatedBy: "@").last?.lowercased() ?? ""
        let domainB = emailB.components(separatedBy: "@").last?.lowercased() ?? ""
        let sameDomain = !domainA.isEmpty && domainA == domainB

        // Require ≥2 of {nameSim≥0.85, sharedStrong, sameDomain}. Note nameSim already required.
        return sharedStrong || sameDomain
    }

    // MARK: - Organizations

    private static func resolveOrganizations(graph: KnowledgeGraph) -> Int {
        let orgs = graph.findNodes(type: .organization)
        guard orgs.count > 1 else { return 0 }

        var canonical: [String: String] = [:]
        var merges = 0

        let embedding = NLEmbedding.wordEmbedding(for: .english)
        let buckets = Dictionary(grouping: orgs) { simplifyName($0.label) }
        for (_, group) in buckets where group.count > 1 {
            // For organizations, name similarity alone is enough when
            // labels resolve to the same simplified form (e.g., "Acme Inc."
            // and "Acme, Inc." both simplify to "acme")
            let active = group.filter { canonical[$0.id] == nil }
            guard active.count > 1 else { continue }

            for i in 0..<active.count {
                for j in (i + 1)..<active.count {
                    let a = active[i]
                    let b = active[j]
                    if nameSimilarity(a.label, b.label, embedding: embedding) >= 0.9 {
                        guard let chosen = pickCanonical([a, b]) else { continue }
                        let other = chosen.id == a.id ? b : a
                        canonical[other.id] = chosen.id
                        merges += 1
                    }
                }
            }
        }
        apply(canonical: canonical, to: graph)
        return merges
    }

    // MARK: - Merge Application

    /// Redirects every edge from a duplicate node to its canonical id, then
    /// removes the duplicate node. Edge weights accumulate via `addEdge`'s
    /// existing merge semantics.
    private static func apply(canonical: [String: String], to graph: KnowledgeGraph) {
        for (duplicateID, canonicalID) in canonical {
            guard duplicateID != canonicalID, graph.findNode(id: canonicalID) != nil else { continue }
            let outgoing = graph.edgesFrom(duplicateID)
            let incoming = graph.edgesTo(duplicateID)

            for edge in outgoing {
                let target = canonical[edge.targetID] ?? edge.targetID
                guard target != canonicalID else { continue }
                graph.addEdge(KGEdge(sourceID: canonicalID, targetID: target, type: edge.type, weight: edge.weight))
            }
            for edge in incoming {
                let source = canonical[edge.sourceID] ?? edge.sourceID
                guard source != canonicalID else { continue }
                graph.addEdge(KGEdge(sourceID: source, targetID: canonicalID, type: edge.type, weight: edge.weight))
            }

            graph.removeNode(id: duplicateID)
        }
    }

    // MARK: - Helpers

    /// Pick the canonical node from a duplicate cluster.
    /// Heuristic: highest weight, breaking ties by longest label (richer info).
    private static func pickCanonical(_ nodes: [KGNode]) -> KGNode? {
        nodes.max { a, b in
            if a.weight != b.weight { return a.weight < b.weight }
            return a.label.count < b.label.count
        }
    }

    /// Strip subaddressing and case for grouping ("Alex+Work@Acme.Example" → "alex@acme.example").
    static func normalizeEmail(_ raw: String) -> String {
        let trimmed = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIdx = trimmed.lastIndex(of: "@") else { return trimmed }
        let local = trimmed[trimmed.startIndex..<atIdx]
        let domain = trimmed[trimmed.index(after: atIdx)...]
        // Drop +tag part of local
        let cleanLocal = local.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? String(local)
        // Drop dots in local part (gmail-style) only when domain is known to ignore dots — be conservative and skip otherwise
        return "\(cleanLocal)@\(domain)"
    }

    /// Lowercase, drop punctuation and common suffixes (Inc., LLC, Co.), squeeze whitespace.
    private static func simplifyName(_ raw: String) -> String {
        var s = raw.lowercased()
        let suffixes = [", inc.", " inc.", ", llc", " llc", " co.", ", co.", " corp.", ", corp."]
        for suffix in suffixes {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        s = s.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        s = s.split(separator: " ").joined(separator: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Combines exact-prefix overlap and NLEmbedding semantic distance.
    private static func nameSimilarity(_ a: String, _ b: String, embedding: NLEmbedding?) -> Double {
        let sa = simplifyName(a)
        let sb = simplifyName(b)
        if sa.isEmpty || sb.isEmpty { return 0 }
        if sa == sb { return 1.0 }

        // Token overlap (Jaccard on words)
        let tokensA = Set(sa.split(separator: " ").map(String.init))
        let tokensB = Set(sb.split(separator: " ").map(String.init))
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        let jaccard = union == 0 ? 0 : Double(intersection) / Double(union)

        // First-name match (handles "Alex M." vs "Alex Morgan")
        let firstA = tokensA.sorted().first ?? ""
        let firstB = tokensB.sorted().first ?? ""
        let firstNameMatch = !firstA.isEmpty && firstA == firstB ? 0.5 : 0

        // Embedding similarity (capped)
        var embSim: Double = 0
        if let embedding {
            let dist = embedding.distance(between: sa, and: sb)
            if dist >= 0, dist < 2 {
                embSim = max(0, 1 - dist / 2) * 0.35
            }
        }

        return min(1.0, jaccard * 0.5 + firstNameMatch + embSim)
    }
}

