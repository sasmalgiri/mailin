import Foundation
import NaturalLanguage

// MARK: - Knowledge Graph Data Model (v3.1.1)

enum KGNodeType: String, Codable, CaseIterable {
    case person
    case organization
    case topic
    case email
    case domain
}

struct KGNode: Identifiable, Codable, Hashable {
    let id: String
    let type: KGNodeType
    var label: String
    var properties: [String: String] = [:]
    var weight: Double = 1.0
    var lastSeen: Date?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: KGNode, rhs: KGNode) -> Bool {
        lhs.id == rhs.id
    }
}

enum KGEdgeType: String, Codable, CaseIterable {
    case communicatesWith
    case discussesTopic
    case mentionedIn
    case reportsTo
    case belongsToOrg
    case sentFrom
    case receivedBy
    case sameThread
}

struct KGEdge: Identifiable, Codable {
    let id: String
    let sourceID: String
    let targetID: String
    let type: KGEdgeType
    var weight: Double = 1.0
    var properties: [String: String] = [:]
    var lastSeen: Date?

    init(sourceID: String, targetID: String, type: KGEdgeType, weight: Double = 1.0) {
        self.id = "\(sourceID)-\(type.rawValue)-\(targetID)"
        self.sourceID = sourceID
        self.targetID = targetID
        self.type = type
        self.weight = weight
    }
}

// MARK: - Knowledge Graph

class KnowledgeGraph: Codable, @unchecked Sendable {
    private(set) var nodes: [String: KGNode] = [:]
    private(set) var edges: [String: KGEdge] = [:]
    private var adjacency: [String: Set<String>] = [:]
    private var reverseAdjacency: [String: Set<String>] = [:]
    private var dirtyNodeIDs: Set<String> = []
    private var dirtyEdgeIDs: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case nodes, edges
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode([String: KGNode].self, forKey: .nodes)
        edges = try container.decode([String: KGEdge].self, forKey: .edges)
        rebuildAdjacency()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
    }

    // MARK: - Node Operations

    @discardableResult
    func addNode(_ node: KGNode) -> KGNode {
        if var existing = nodes[node.id] {
            existing.weight += node.weight
            existing.lastSeen = node.lastSeen ?? existing.lastSeen
            for (k, v) in node.properties {
                existing.properties[k] = v
            }
            nodes[node.id] = existing
            dirtyNodeIDs.insert(node.id)
            return existing
        }
        nodes[node.id] = node
        adjacency[node.id] = adjacency[node.id] ?? []
        reverseAdjacency[node.id] = reverseAdjacency[node.id] ?? []
        dirtyNodeIDs.insert(node.id)
        return node
    }

    func findNode(id: String) -> KGNode? {
        nodes[id]
    }

    func findNodes(type: KGNodeType) -> [KGNode] {
        nodes.values.filter { $0.type == type }
    }

    func findNodes(matching query: String) -> [KGNode] {
        let lower = query.lowercased()
        return nodes.values.filter {
            $0.label.lowercased().contains(lower) ||
            $0.properties.values.contains(where: { $0.lowercased().contains(lower) })
        }
    }

    // MARK: - Edge Operations

    @discardableResult
    func addEdge(_ edge: KGEdge) -> KGEdge {
        guard nodes[edge.sourceID] != nil, nodes[edge.targetID] != nil else { return edge }

        if var existing = edges[edge.id] {
            existing.weight += edge.weight
            existing.lastSeen = edge.lastSeen ?? existing.lastSeen
            for (k, v) in edge.properties {
                existing.properties[k] = v
            }
            edges[edge.id] = existing
            dirtyEdgeIDs.insert(edge.id)
            return existing
        }

        edges[edge.id] = edge
        adjacency[edge.sourceID, default: []].insert(edge.id)
        reverseAdjacency[edge.targetID, default: []].insert(edge.id)
        dirtyEdgeIDs.insert(edge.id)
        return edge
    }

    func edgesFrom(_ nodeID: String) -> [KGEdge] {
        (adjacency[nodeID] ?? []).compactMap { edges[$0] }
    }

    func edgesTo(_ nodeID: String) -> [KGEdge] {
        (reverseAdjacency[nodeID] ?? []).compactMap { edges[$0] }
    }

    func edgesBetween(_ nodeA: String, _ nodeB: String) -> [KGEdge] {
        let forward = edgesFrom(nodeA).filter { $0.targetID == nodeB }
        let backward = edgesFrom(nodeB).filter { $0.targetID == nodeA }
        return forward + backward
    }

    // MARK: - Graph Queries

    func neighbors(of nodeID: String, type: KGEdgeType? = nil) -> [KGNode] {
        let outgoing = edgesFrom(nodeID)
        let incoming = edgesTo(nodeID)
        let neighborIDs: Set<String>

        if let type {
            let outIDs = outgoing.filter { $0.type == type }.map(\.targetID)
            let inIDs = incoming.filter { $0.type == type }.map(\.sourceID)
            neighborIDs = Set(outIDs + inIDs)
        } else {
            let outIDs = outgoing.map(\.targetID)
            let inIDs = incoming.map(\.sourceID)
            neighborIDs = Set(outIDs + inIDs)
        }

        return neighborIDs.compactMap { nodes[$0] }
    }

    func shortestPath(from sourceID: String, to targetID: String) -> [String]? {
        guard nodes[sourceID] != nil, nodes[targetID] != nil else { return nil }
        if sourceID == targetID { return [sourceID] }

        var visited: Set<String> = [sourceID]
        var queue: [(String, [String])] = [(sourceID, [sourceID])]

        while !queue.isEmpty {
            let (current, path) = queue.removeFirst()
            let neighborNodes = neighbors(of: current)

            for neighbor in neighborNodes {
                if neighbor.id == targetID {
                    return path + [neighbor.id]
                }
                if !visited.contains(neighbor.id) {
                    visited.insert(neighbor.id)
                    queue.append((neighbor.id, path + [neighbor.id]))
                }
            }

            if visited.count > 500 { break }
        }

        return nil
    }

    func subgraph(around nodeID: String, depth: Int = 2) -> KnowledgeGraph {
        let sub = KnowledgeGraph()
        guard let root = nodes[nodeID] else { return sub }

        var visited: Set<String> = [nodeID]
        var frontier: Set<String> = [nodeID]
        sub.addNode(root)

        for _ in 0..<depth {
            var nextFrontier: Set<String> = []
            for id in frontier {
                for edge in edgesFrom(id) + edgesTo(id) {
                    let neighborID = edge.sourceID == id ? edge.targetID : edge.sourceID
                    if let neighborNode = nodes[neighborID] {
                        sub.addNode(neighborNode)
                        sub.addEdge(edge)
                        if !visited.contains(neighborID) {
                            visited.insert(neighborID)
                            nextFrontier.insert(neighborID)
                        }
                    }
                }
            }
            frontier = nextFrontier
        }

        return sub
    }

    func topNodes(by type: KGNodeType, limit: Int = 10) -> [KGNode] {
        findNodes(type: type)
            .sorted { $0.weight > $1.weight }
            .prefix(limit)
            .map { $0 }
    }

    func connectionStrength(between nodeA: String, nodeB: String) -> Double {
        edgesBetween(nodeA, nodeB).reduce(0) { $0 + $1.weight }
    }

    // MARK: - Statistics

    var nodeCount: Int { nodes.count }
    var edgeCount: Int { edges.count }
    var allNodes: [KGNode] { Array(nodes.values) }
    var allEdges: [KGEdge] { Array(edges.values) }

    func statistics() -> (people: Int, orgs: Int, topics: Int, emails: Int, domains: Int, edges: Int) {
        let people = findNodes(type: .person).count
        let orgs = findNodes(type: .organization).count
        let topics = findNodes(type: .topic).count
        let emails = findNodes(type: .email).count
        let domains = findNodes(type: .domain).count
        return (people, orgs, topics, emails, domains, edges.count)
    }

    // MARK: - Persistence

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("knowledge_graph.json")
    }

    func save() {
        guard !dirtyNodeIDs.isEmpty || !dirtyEdgeIDs.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.storageURL, options: .atomic)
            dirtyNodeIDs.removeAll()
            dirtyEdgeIDs.removeAll()
        } catch {
            // Silent fail — graph is non-critical
        }
    }

    static func load() -> KnowledgeGraph {
        guard let data = try? Data(contentsOf: storageURL),
              let graph = try? JSONDecoder().decode(KnowledgeGraph.self, from: data) else {
            return KnowledgeGraph()
        }
        return graph
    }

    func clear() {
        nodes.removeAll()
        edges.removeAll()
        adjacency.removeAll()
        reverseAdjacency.removeAll()
        dirtyNodeIDs.removeAll()
        dirtyEdgeIDs.removeAll()
        try? FileManager.default.removeItem(at: Self.storageURL)
    }

    // MARK: - Internal

    private func rebuildAdjacency() {
        adjacency.removeAll()
        reverseAdjacency.removeAll()
        for (_, node) in nodes {
            adjacency[node.id] = []
            reverseAdjacency[node.id] = []
        }
        for (id, edge) in edges {
            adjacency[edge.sourceID, default: []].insert(id)
            reverseAdjacency[edge.targetID, default: []].insert(id)
        }
    }

    // MARK: - Graph Summary for AI Context

    func summaryForAI(focus: String? = nil, limit: Int = 20) -> String {
        var summary = "KNOWLEDGE GRAPH (\(nodeCount) nodes, \(edgeCount) edges):\n"

        let stats = statistics()
        summary += "People: \(stats.people), Orgs: \(stats.orgs), Topics: \(stats.topics), Domains: \(stats.domains)\n"

        let topPeople = topNodes(by: .person, limit: 5)
        if !topPeople.isEmpty {
            summary += "KEY PEOPLE: " + topPeople.map { "\($0.label) (w:\(String(format: "%.0f", $0.weight)))" }.joined(separator: ", ") + "\n"
        }

        let topOrgs = topNodes(by: .organization, limit: 3)
        if !topOrgs.isEmpty {
            summary += "KEY ORGS: " + topOrgs.map { "\($0.label) (w:\(String(format: "%.0f", $0.weight)))" }.joined(separator: ", ") + "\n"
        }

        let topTopics = topNodes(by: .topic, limit: 5)
        if !topTopics.isEmpty {
            summary += "KEY TOPICS: " + topTopics.map { "\($0.label) (w:\(String(format: "%.0f", $0.weight)))" }.joined(separator: ", ") + "\n"
        }

        if let focus, !focus.isEmpty {
            let focusNodes = findNodes(matching: focus)
            if !focusNodes.isEmpty {
                summary += "FOCUS (\(focus)):\n"
                for node in focusNodes.prefix(3) {
                    let neighborList = neighbors(of: node.id).prefix(5)
                    summary += "  \(node.label) (\(node.type.rawValue)) → \(neighborList.map(\.label).joined(separator: ", "))\n"
                }
            }
        }

        // Top relationships by weight
        let topEdges = edges.values.sorted { $0.weight > $1.weight }.prefix(limit)
        if !topEdges.isEmpty {
            summary += "STRONGEST CONNECTIONS:\n"
            for edge in topEdges.prefix(8) {
                let src = nodes[edge.sourceID]?.label ?? edge.sourceID
                let tgt = nodes[edge.targetID]?.label ?? edge.targetID
                summary += "  \(src) --[\(edge.type.rawValue) w:\(String(format: "%.0f", edge.weight))]--> \(tgt)\n"
            }
        }

        return summary
    }

    // MARK: - Knowledge Graph Comparison (v3.6.1)

    struct GraphComparison {
        var newContacts: [KGNode]
        var lostContacts: [KGNode]
        var strengthenedEdges: [(source: String, target: String, type: String, delta: Double)]
        var weakenedEdges: [(source: String, target: String, type: String, delta: Double)]
        var newTopics: [KGNode]
        var lostTopics: [KGNode]

        func summaryText() -> String {
            var text = ""
            if !newContacts.isEmpty {
                text += "NEW CONTACTS: \(newContacts.map(\.label).joined(separator: ", "))\n"
            }
            if !lostContacts.isEmpty {
                text += "LOST CONTACTS: \(lostContacts.map(\.label).joined(separator: ", "))\n"
            }
            if !strengthenedEdges.isEmpty {
                text += "STRENGTHENED: \(strengthenedEdges.prefix(5).map { "\($0.source)->\($0.target) +\(String(format: "%.0f", $0.delta))" }.joined(separator: ", "))\n"
            }
            if !weakenedEdges.isEmpty {
                text += "WEAKENED: \(weakenedEdges.prefix(5).map { "\($0.source)->\($0.target) \(String(format: "%.0f", $0.delta))" }.joined(separator: ", "))\n"
            }
            if !newTopics.isEmpty {
                text += "NEW TOPICS: \(newTopics.map(\.label).joined(separator: ", "))\n"
            }
            if !lostTopics.isEmpty {
                text += "LOST TOPICS: \(lostTopics.map(\.label).joined(separator: ", "))\n"
            }
            return text
        }
    }

    func compare(to other: KnowledgeGraph) -> GraphComparison {
        let selfPeople = Set(findNodes(type: .person).map(\.id))
        let otherPeople = Set(other.findNodes(type: .person).map(\.id))
        let newContactIDs = otherPeople.subtracting(selfPeople)
        let lostContactIDs = selfPeople.subtracting(otherPeople)

        let newContacts = newContactIDs.compactMap { other.findNode(id: $0) }
        let lostContacts = lostContactIDs.compactMap { findNode(id: $0) }

        let selfTopics = Set(findNodes(type: .topic).map(\.id))
        let otherTopics = Set(other.findNodes(type: .topic).map(\.id))
        let newTopics = otherTopics.subtracting(selfTopics).compactMap { other.findNode(id: $0) }
        let lostTopics = selfTopics.subtracting(otherTopics).compactMap { findNode(id: $0) }

        var strengthened: [(source: String, target: String, type: String, delta: Double)] = []
        var weakened: [(source: String, target: String, type: String, delta: Double)] = []

        let commonPeople = selfPeople.intersection(otherPeople)
        for personID in commonPeople {
            let selfEdges = edgesFrom(personID)
            let otherEdgeMap = Dictionary(
                other.edgesFrom(personID).map { ("\($0.targetID):\($0.type.rawValue)", $0) },
                uniquingKeysWith: { a, _ in a }
            )

            for edge in selfEdges {
                let key = "\(edge.targetID):\(edge.type.rawValue)"
                if let otherEdge = otherEdgeMap[key] {
                    let delta = otherEdge.weight - edge.weight
                    let srcLabel = nodes[edge.sourceID]?.label ?? edge.sourceID
                    let tgtLabel = nodes[edge.targetID]?.label ?? edge.targetID
                    if delta > 2.0 {
                        strengthened.append((source: srcLabel, target: tgtLabel, type: edge.type.rawValue, delta: delta))
                    } else if delta < -2.0 {
                        weakened.append((source: srcLabel, target: tgtLabel, type: edge.type.rawValue, delta: delta))
                    }
                }
            }
        }

        strengthened.sort { $0.delta > $1.delta }
        weakened.sort { $0.delta < $1.delta }

        return GraphComparison(
            newContacts: Array(newContacts.sorted { $0.weight > $1.weight }.prefix(10)),
            lostContacts: Array(lostContacts.sorted { $0.weight > $1.weight }.prefix(10)),
            strengthenedEdges: Array(strengthened.prefix(10)),
            weakenedEdges: Array(weakened.prefix(10)),
            newTopics: Array(newTopics.sorted { $0.weight > $1.weight }.prefix(10)),
            lostTopics: Array(lostTopics.sorted { $0.weight > $1.weight }.prefix(10))
        )
    }
}

// MARK: - Knowledge Graph Builder (v3.1.2)

struct KnowledgeGraphBuilder {

    static func build(from emails: [MBOXParser.RawEmail], into graph: KnowledgeGraph) {
        let now = Date()

        for email in emails {
            let fromAddr = extractEmail(from: email.headers["From"] ?? "")
            let fromName = extractName(from: email.headers["From"] ?? "")
            guard !fromAddr.isEmpty else { continue }

            // Person node for sender
            let senderID = "person:\(fromAddr.lowercased())"
            graph.addNode(KGNode(
                id: senderID, type: .person,
                label: fromName.isEmpty ? fromAddr : fromName,
                properties: ["email": fromAddr],
                weight: 1.0, lastSeen: now
            ))

            // Domain node for sender
            let senderDomain = fromAddr.components(separatedBy: "@").last?.lowercased() ?? ""
            if !senderDomain.isEmpty {
                let domainID = "domain:\(senderDomain)"
                graph.addNode(KGNode(
                    id: domainID, type: .domain,
                    label: senderDomain,
                    weight: 1.0, lastSeen: now
                ))
                graph.addEdge(KGEdge(sourceID: senderID, targetID: domainID, type: .belongsToOrg))
            }

            // Recipients — To, Cc
            var recipientIDs: [String] = []
            let allRecipients = (email.headers["To"] ?? "") + ", " + (email.headers["Cc"] ?? "")
            let recipientAddresses = parseAddressList(allRecipients)

            for addr in recipientAddresses {
                let recipAddr = addr.lowercased()
                let recipID = "person:\(recipAddr)"
                let recipName = extractName(from: addr)
                graph.addNode(KGNode(
                    id: recipID, type: .person,
                    label: recipName.isEmpty ? recipAddr : recipName,
                    properties: ["email": recipAddr],
                    weight: 1.0, lastSeen: now
                ))
                recipientIDs.append(recipID)

                // Communication edge: sender → recipient
                graph.addEdge(KGEdge(sourceID: senderID, targetID: recipID, type: .communicatesWith))

                // Recipient domain
                let recipDomain = recipAddr.components(separatedBy: "@").last ?? ""
                if !recipDomain.isEmpty {
                    let rDomainID = "domain:\(recipDomain)"
                    graph.addNode(KGNode(
                        id: rDomainID, type: .domain,
                        label: recipDomain,
                        weight: 1.0, lastSeen: now
                    ))
                    graph.addEdge(KGEdge(sourceID: recipID, targetID: rDomainID, type: .belongsToOrg))
                }
            }
        }

        // Extract entities and topics via NLP (batch for efficiency)
        extractEntitiesIntoGraph(emails: emails, graph: graph, now: now)
        extractTopicsIntoGraph(emails: emails, graph: graph, now: now)

        // Strengthen edges between thread participants
        strengthenThreadEdges(emails: emails, graph: graph)

        graph.save()
    }

    // MARK: - Entity Extraction

    private static func extractEntitiesIntoGraph(emails: [MBOXParser.RawEmail], graph: KnowledgeGraph, now: Date) {
        let entities = EmailNLPEngine.extractEntities(from: emails, limit: 50)

        for entity in entities {
            let nodeType: KGNodeType
            switch entity.type {
            case "PersonalName": nodeType = .person
            case "OrganizationName": nodeType = .organization
            default: continue
            }

            let entityID = "\(nodeType.rawValue):\(entity.name.lowercased())"
            graph.addNode(KGNode(
                id: entityID, type: nodeType,
                label: entity.name,
                weight: Double(entity.count),
                lastSeen: now
            ))
        }
    }

    // MARK: - Topic Extraction

    private static func extractTopicsIntoGraph(emails: [MBOXParser.RawEmail], graph: KnowledgeGraph, now: Date) {
        let topics = EmailNLPEngine.extractTopics(from: emails, limit: 30)

        for topic in topics {
            let topicID = "topic:\(topic.word.lowercased())"
            graph.addNode(KGNode(
                id: topicID, type: .topic,
                label: topic.word,
                weight: Double(topic.count),
                lastSeen: now
            ))
        }

        // Connect people to topics they discuss
        for email in emails.prefix(200) {
            let fromAddr = extractEmail(from: email.headers["From"] ?? "").lowercased()
            guard !fromAddr.isEmpty else { continue }
            let senderID = "person:\(fromAddr)"

            let emailTopics = EmailNLPEngine.extractTopics(from: [email], limit: 3)
            for topic in emailTopics {
                let topicID = "topic:\(topic.word.lowercased())"
                if graph.findNode(id: topicID) != nil {
                    graph.addEdge(KGEdge(sourceID: senderID, targetID: topicID, type: .discussesTopic))
                }
            }
        }
    }

    // MARK: - Thread Strengthening

    private static func strengthenThreadEdges(emails: [MBOXParser.RawEmail], graph: KnowledgeGraph) {
        let threads = ThreadGrouper.group(emails).filter { $0.count > 1 }

        for thread in threads {
            let participants = thread.allEmails.compactMap {
                extractEmail(from: $0.headers["From"] ?? "").lowercased()
            }.filter { !$0.isEmpty }
            let uniqueParticipants = Array(Set(participants))

            // Strengthen edges between all pairs of thread participants
            for i in 0..<uniqueParticipants.count {
                for j in (i+1)..<uniqueParticipants.count {
                    let idA = "person:\(uniqueParticipants[i])"
                    let idB = "person:\(uniqueParticipants[j])"
                    graph.addEdge(KGEdge(
                        sourceID: idA, targetID: idB,
                        type: .sameThread,
                        weight: Double(thread.count)
                    ))
                }
            }
        }
    }

    // MARK: - Address Parsing Helpers

    private static func extractEmail(from header: String) -> String {
        if let start = header.lastIndex(of: "<"), let end = header.lastIndex(of: ">") {
            return String(header[header.index(after: start)..<end]).trimmingCharacters(in: .whitespaces)
        }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") ? trimmed : ""
    }

    private static func extractName(from header: String) -> String {
        if let start = header.firstIndex(of: "<") {
            let name = String(header[header.startIndex..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.replacingOccurrences(of: "\"", with: "")
        }
        return ""
    }

    private static func parseAddressList(_ list: String) -> [String] {
        list.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { extractEmail(from: $0) }
            .filter { !$0.isEmpty }
    }
}
