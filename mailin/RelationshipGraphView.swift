//
//  RelationshipGraphView.swift
//  mailin
//
//  Contact network visualization using force-directed graph layout.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Graph Layout Engine

@Observable
class GraphLayout {
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    var isReady = false

    struct GraphNode: Identifiable {
        let id: String  // email address
        var name: String
        var emailCount: Int
        var sentiment: Double  // -1.0 to 1.0
        var position: CGPoint
        var velocity: CGPoint = .zero
        var lastContactDate: Date?
        var sentCount: Int = 0
        var receivedCount: Int = 0
        var isCenterNode: Bool = false
    }

    struct GraphEdge: Identifiable {
        var id: String { "\(from)-\(to)" }
        let from: String
        let to: String
        var weight: Int  // email count between them
    }

    func buildGraph(from emails: [MBOXParser.RawEmail], senderEmail: String) {
        guard !senderEmail.isEmpty else { return }

        var contactData: [String: (name: String, count: Int, sent: Int, received: Int, lastDate: Date?, sentiment: Double, sentimentCount: Int)] = [:]
        var edgeData: [String: Int] = [:]

        let senderLower = senderEmail.lowercased()

        for email in emails {
            let from = email.headers["From"] ?? ""
            let toField = email.headers["To"] ?? ""
            let ccField = email.headers["Cc"] ?? ""
            let date = MBOXParser.parseDate(email.headers["Date"])

            // Simple sentiment heuristic from subject/body keywords
            let text = (email.headers["Subject"] ?? "") + " " + email.plainBody.prefix(500)
            let sentimentScore = Self.quickSentiment(text)

            // Extract addresses from To and Cc
            let allRecipients = Self.extractAddresses(from: toField) + Self.extractAddresses(from: ccField)
            let fromAddress = Self.extractAddresses(from: from).first

            if email.messageType == "sent" {
                // User sent this; recipients are contacts
                for recipient in allRecipients {
                    let addr = recipient.address.lowercased()
                    if addr == senderLower { continue }
                    var entry = contactData[addr] ?? (name: recipient.name.isEmpty ? addr : recipient.name, count: 0, sent: 0, received: 0, lastDate: nil, sentiment: 0, sentimentCount: 0)
                    entry.count += 1
                    entry.sent += 1
                    if let date, (entry.lastDate.map({ date > $0 }) ?? true) { entry.lastDate = date }
                    entry.sentiment += sentimentScore
                    entry.sentimentCount += 1
                    if !recipient.name.isEmpty && entry.name == addr { entry.name = recipient.name }
                    contactData[addr] = entry

                    let edgeKey = [senderLower, addr].sorted().joined(separator: "|")
                    edgeData[edgeKey, default: 0] += 1
                }
            } else {
                // Received; sender is a contact
                if let fromAddr = fromAddress {
                    let addr = fromAddr.address.lowercased()
                    if addr != senderLower {
                        var entry = contactData[addr] ?? (name: fromAddr.name.isEmpty ? addr : fromAddr.name, count: 0, sent: 0, received: 0, lastDate: nil, sentiment: 0, sentimentCount: 0)
                        entry.count += 1
                        entry.received += 1
                        if let date, (entry.lastDate.map({ date > $0 }) ?? true) { entry.lastDate = date }
                        entry.sentiment += sentimentScore
                        entry.sentimentCount += 1
                        if !fromAddr.name.isEmpty && entry.name == addr { entry.name = fromAddr.name }
                        contactData[addr] = entry

                        let edgeKey = [senderLower, addr].sorted().joined(separator: "|")
                        edgeData[edgeKey, default: 0] += 1
                    }
                }
            }
        }

        // Build nodes - limit to top 40 contacts by volume for readability
        let sortedContacts = contactData.sorted { $0.value.count > $1.value.count }
        let topContacts = Array(sortedContacts.prefix(40))

        var graphNodes: [GraphNode] = []
        // Center node for user
        graphNodes.append(GraphNode(
            id: senderLower,
            name: "You",
            emailCount: emails.count,
            sentiment: 0,
            position: .zero,
            isCenterNode: true
        ))

        let topAddresses = Set(topContacts.map { $0.key })

        for (addr, data) in topContacts {
            let avgSentiment = data.sentimentCount > 0 ? data.sentiment / Double(data.sentimentCount) : 0
            graphNodes.append(GraphNode(
                id: addr,
                name: data.name,
                emailCount: data.count,
                sentiment: max(-1, min(1, avgSentiment)),
                position: .zero,
                lastContactDate: data.lastDate,
                sentCount: data.sent,
                receivedCount: data.received
            ))
        }

        var graphEdges: [GraphEdge] = []
        for (key, weight) in edgeData {
            let parts = key.split(separator: "|")
            guard parts.count == 2 else { continue }
            let a = String(parts[0])
            let b = String(parts[1])
            if (a == senderLower && topAddresses.contains(b)) ||
               (b == senderLower && topAddresses.contains(a)) {
                graphEdges.append(GraphEdge(from: a, to: b, weight: weight))
            }
        }

        nodes = graphNodes
        edges = graphEdges
    }

    func runSimulation(iterations: Int, bounds: CGSize) {
        guard nodes.count > 1 else {
            if nodes.count == 1 {
                nodes[0].position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            }
            isReady = true
            return
        }

        let centerX = bounds.width / 2
        let centerY = bounds.height / 2

        // Initialize positions in a circle around center
        let radius = min(bounds.width, bounds.height) * 0.35
        for i in nodes.indices {
            if nodes[i].isCenterNode {
                nodes[i].position = CGPoint(x: centerX, y: centerY)
            } else {
                let divisor = max(1, nodes.count - 1)
                let angle = (2 * Double.pi * Double(i)) / Double(divisor)
                nodes[i].position = CGPoint(
                    x: centerX + radius * cos(angle) + Double.random(in: -20...20),
                    y: centerY + radius * sin(angle) + Double.random(in: -20...20)
                )
            }
        }

        let maxWeight = Double(edges.map { $0.weight }.max() ?? 1)

        for iteration in 0..<iterations {
            let temperature = max(0.1, 1.0 - Double(iteration) / Double(iterations))
            let damping = 0.85

            // Reset forces
            var forces = [CGPoint](repeating: .zero, count: nodes.count)

            // Repulsive force between all nodes (Coulomb's law)
            let repulsionStrength: CGFloat = 8000
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    let dx = nodes[i].position.x - nodes[j].position.x
                    let dy = nodes[i].position.y - nodes[j].position.y
                    let distSq = max(dx * dx + dy * dy, 100)
                    let dist = sqrt(distSq)
                    let force = repulsionStrength / distSq
                    let fx = force * dx / dist
                    let fy = force * dy / dist
                    forces[i].x += fx
                    forces[i].y += fy
                    forces[j].x -= fx
                    forces[j].y -= fy
                }
            }

            // Attractive force along edges (spring force)
            let springStrength: CGFloat = 0.02
            let idealLength: CGFloat = 120
            let nodeIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })

            for edge in edges {
                guard let fromIdx = nodeIndex[edge.from],
                      let toIdx = nodeIndex[edge.to] else { continue }
                let dx = nodes[toIdx].position.x - nodes[fromIdx].position.x
                let dy = nodes[toIdx].position.y - nodes[fromIdx].position.y
                let dist = max(sqrt(dx * dx + dy * dy), 1)
                let weightFactor = CGFloat(Double(edge.weight) / maxWeight)
                let attraction = springStrength * (dist - idealLength) * (1 + weightFactor)
                let fx = attraction * dx / dist
                let fy = attraction * dy / dist
                forces[fromIdx].x += fx
                forces[fromIdx].y += fy
                forces[toIdx].x -= fx
                forces[toIdx].y -= fy
            }

            // Center gravity
            let gravity: CGFloat = 0.05
            for i in 0..<nodes.count {
                let dx = centerX - nodes[i].position.x
                let dy = centerY - nodes[i].position.y
                forces[i].x += gravity * dx
                forces[i].y += gravity * dy
            }

            // Apply forces
            for i in 0..<nodes.count {
                if nodes[i].isCenterNode {
                    // Keep center node fixed
                    nodes[i].position = CGPoint(x: centerX, y: centerY)
                    continue
                }
                nodes[i].velocity.x = (nodes[i].velocity.x + forces[i].x * temperature) * damping
                nodes[i].velocity.y = (nodes[i].velocity.y + forces[i].y * temperature) * damping

                // Limit velocity
                let speed = sqrt(nodes[i].velocity.x * nodes[i].velocity.x + nodes[i].velocity.y * nodes[i].velocity.y)
                let maxSpeed: CGFloat = 50 * temperature
                if speed > maxSpeed {
                    nodes[i].velocity.x *= maxSpeed / speed
                    nodes[i].velocity.y *= maxSpeed / speed
                }

                nodes[i].position.x += nodes[i].velocity.x
                nodes[i].position.y += nodes[i].velocity.y

                // Keep within bounds with padding
                let padding: CGFloat = 30
                nodes[i].position.x = max(padding, min(bounds.width - padding, nodes[i].position.x))
                nodes[i].position.y = max(padding, min(bounds.height - padding, nodes[i].position.y))
            }
        }

        isReady = true
    }

    // MARK: - Helpers

    struct ParsedAddress {
        let name: String
        let address: String
    }

    static func extractAddresses(from field: String) -> [ParsedAddress] {
        let parts = field.components(separatedBy: ",")
        return parts.compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let angleBracketStart = trimmed.firstIndex(of: "<"),
               let angleBracketEnd = trimmed.firstIndex(of: ">") {
                let address = String(trimmed[trimmed.index(after: angleBracketStart)..<angleBracketEnd])
                let name = String(trimmed[trimmed.startIndex..<angleBracketStart])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return ParsedAddress(name: name, address: address)
            }

            if trimmed.contains("@") {
                return ParsedAddress(name: "", address: trimmed)
            }

            return nil
        }
    }

    static func quickSentiment(_ text: String) -> Double {
        let lower = text.lowercased()
        let positiveWords = ["thank", "thanks", "great", "good", "excellent", "wonderful", "happy",
                             "pleased", "appreciate", "love", "congrat", "welcome", "agree", "perfect"]
        let negativeWords = ["urgent", "problem", "issue", "error", "fail", "complaint", "sorry",
                             "unfortunately", "disagree", "wrong", "bad", "terrible", "disappointed", "angry"]
        var score = 0.0
        for word in positiveWords where lower.contains(word) { score += 0.15 }
        for word in negativeWords where lower.contains(word) { score -= 0.15 }
        return max(-1, min(1, score))
    }
}

// MARK: - Relationship Graph View

struct RelationshipGraphView: View {
    let emails: [MBOXParser.RawEmail]
    let senderEmail: String

    @State private var graphLayout = GraphLayout()
    @State private var selectedNodeID: String?
    @State private var graphSize: CGSize = CGSize(width: 600, height: 450)
    @State private var aiInsights: String?
    @State private var isLoadingAI = false
    @Environment(\.dismiss) private var dismiss

    // MARK: - Computed

    private var selectedNode: GraphLayout.GraphNode? {
        guard let id = selectedNodeID else { return nil }
        return graphLayout.nodes.first { $0.id == id }
    }

    private var topContacts: [GraphLayout.GraphNode] {
        graphLayout.nodes
            .filter { !$0.isCenterNode }
            .sorted { $0.emailCount > $1.emailCount }
    }

    private var totalContacts: Int {
        graphLayout.nodes.count - 1  // exclude center
    }

    private var mostActive: GraphLayout.GraphNode? {
        topContacts.first
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if emails.isEmpty {
                emptyState
            } else if !graphLayout.isReady {
                loadingState
            } else {
                content
            }
        }
        .onAppear { buildAndSimulate() }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text("Relationship Graph")
                    .font(Typography.title3)
                Text("\(totalContacts) contacts from \(emails.count) emails")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            Button("Rebuild") { buildAndSimulate() }
                .buttonStyle(.bordered)
                .accessibilityLabel("Rebuild the relationship graph")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.medium)
    }

    // MARK: - Empty / Loading

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyStateView(
                icon: "person.3",
                title: "No Relationship Data",
                message: "Import emails to see your contact network."
            )
            Spacer()
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView("Building contact network...")
                .font(Typography.callout)
            Spacer()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        ScrollView {
            VStack(spacing: Spacing.large) {
                graphCanvas
                statsSection
                if let selectedNode {
                    nodeDetailSection(node: selectedNode)
                }
                aiInsightsSection
                topContactsSection
            }
            .padding(Spacing.large)
        }
        #else
        HStack(spacing: 0) {
            // Graph area
            VStack(spacing: Spacing.large) {
                graphCanvas
                statsSection
            }
            .padding(Spacing.large)
            .frame(maxWidth: .infinity)

            Divider()

            // Side panel
            ScrollView {
                VStack(spacing: Spacing.medium) {
                    if let selectedNode {
                        nodeDetailSection(node: selectedNode)
                    }
                    aiInsightsSection
                    topContactsSection
                }
                .padding(Spacing.medium)
            }
            .frame(width: 260)
        }
        #endif
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, canvasSize in
                let nodeIndex = Dictionary(uniqueKeysWithValues: graphLayout.nodes.map { ($0.id, $0) })

                // Draw edges
                for edge in graphLayout.edges {
                    guard let fromNode = nodeIndex[edge.from],
                          let toNode = nodeIndex[edge.to] else { continue }
                    let maxWeight = Double(graphLayout.edges.map { $0.weight }.max() ?? 1)
                    let thickness = max(0.5, 4.0 * Double(edge.weight) / maxWeight)
                    var path = Path()
                    path.move(to: fromNode.position)
                    path.addLine(to: toNode.position)
                    context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: thickness)
                }

                // Draw nodes
                for node in graphLayout.nodes {
                    let maxCount = Double(graphLayout.nodes.map { $0.emailCount }.max() ?? 1)
                    let baseRadius: CGFloat = node.isCenterNode ? 20 : max(8, 18 * CGFloat(Double(node.emailCount) / maxCount))
                    let isSelected = node.id == selectedNodeID

                    let color = node.isCenterNode ? Color.accentColor : nodeColor(for: node.sentiment)
                    let rect = CGRect(
                        x: node.position.x - baseRadius,
                        y: node.position.y - baseRadius,
                        width: baseRadius * 2,
                        height: baseRadius * 2
                    )

                    // Selection ring
                    if isSelected {
                        let selRect = rect.insetBy(dx: -3, dy: -3)
                        context.fill(Path(ellipseIn: selRect), with: .color(color.opacity(0.3)))
                    }

                    context.fill(Path(ellipseIn: rect), with: .color(color))

                    // Label
                    let label = node.isCenterNode ? "You" : shortName(node.name)
                    let textPoint = CGPoint(x: node.position.x, y: node.position.y + baseRadius + 10)
                    context.draw(
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(.primary),
                        at: textPoint
                    )
                }
            }
            .onAppear {
                graphSize = size
                if !graphLayout.isReady {
                    buildAndSimulate()
                }
            }
            .onChange(of: size) { _, newSize in
                graphSize = newSize
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(at: location)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Contact network graph with \(graphLayout.nodes.count) nodes")
        }
        #if os(macOS)
        .frame(minHeight: 350)
        #else
        .frame(minHeight: 250)
        #endif
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: Spacing.medium) {
            miniStat(title: "Contacts", value: "\(totalContacts)")
            if let most = mostActive {
                miniStat(title: "Most Active", value: shortName(most.name))
            }
            miniStat(title: "Total Emails", value: "\(emails.count)")
        }
        .accessibilityElement(children: .combine)
    }

    private func miniStat(title: String, value: String) -> some View {
        VStack(spacing: Spacing.xxxSmall) {
            Text(title)
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
            Text(value)
                .font(Typography.callout)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.small)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.medium)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Node Detail

    private func nodeDetailSection(node: GraphLayout.GraphNode) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("Contact Details")
                    .font(Typography.headline)
                Spacer()
                Button {
                    selectedNodeID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close contact details")
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Label(node.name, systemImage: "person.fill")
                    .font(Typography.callout)
                    .fontWeight(.semibold)
                Label(node.id, systemImage: "envelope")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }

            HStack(spacing: Spacing.medium) {
                detailItem(label: "Total", value: "\(node.emailCount)")
                detailItem(label: "Sent", value: "\(node.sentCount)")
                detailItem(label: "Received", value: "\(node.receivedCount)")
            }

            HStack(spacing: Spacing.medium) {
                detailItem(label: "Sentiment", value: sentimentLabel(node.sentiment))
                if let date = node.lastContactDate {
                    let formatter: DateFormatter = {
                        let f = DateFormatter()
                        f.dateStyle = .medium
                        return f
                    }()
                    detailItem(label: "Last Contact", value: formatter.string(from: date))
                }
            }

            // Sentiment indicator bar
            GeometryReader { geo in
                let width = geo.size.width
                let normalized = (node.sentiment + 1) / 2  // 0 to 1
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(nodeColor(for: node.sentiment))
                        .frame(width: width * normalized)
                }
            }
            .frame(height: 6)

            HStack {
                Text("Negative")
                    .font(.system(size: 9))
                    .foregroundColor(AppColors.error)
                Spacer()
                Text("Neutral")
                    .font(.system(size: 9))
                    .foregroundColor(AppColors.secondary)
                Spacer()
                Text("Positive")
                    .font(.system(size: 9))
                    .foregroundColor(AppColors.success)
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    private func detailItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
            Text(value)
                .font(Typography.callout)
                .fontWeight(.medium)
        }
    }

    // MARK: - AI Insights

    private var aiInsightsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Text("AI Analysis")
                    .font(Typography.callout)
                    .fontWeight(.semibold)
                Spacer()
                if isLoadingAI {
                    ProgressView()
                        .controlSize(.small)
                } else if aiInsights == nil {
                    Button {
                        loadAIInsights()
                    } label: {
                        Label("Enhance with AI", systemImage: "sparkles")
                            .font(Typography.caption1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                }
            }

            if let insights = aiInsights {
                Text(insights)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(Spacing.small)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private func loadAIInsights() {
        isLoadingAI = true
        let topNames = topContacts.prefix(5).map { "\($0.name) (\($0.emailCount))" }.joined(separator: ", ")
        let context = """
        Relationship graph for \(emails.count) emails with \(totalContacts) contacts. \
        Top contacts: \(topNames).
        """
        let emailsCopy = emails
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .entity,
                    emails: emailsCopy,
                    context: context
                )
                aiInsights = result ?? "AI analysis unavailable."
            } else {
                aiInsights = "Requires macOS 26 or later."
            }
            #else
            aiInsights = "AI features not available on this platform."
            #endif
            isLoadingAI = false
        }
    }

    // MARK: - Top Contacts List

    private var topContactsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Top Contacts")
                .font(Typography.headline)

            ForEach(topContacts.prefix(20)) { contact in
                Button {
                    selectedNodeID = contact.id
                } label: {
                    HStack(spacing: Spacing.small) {
                        ContactAvatar(name: contact.name, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.name)
                                .font(Typography.callout)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text("\(contact.emailCount) emails")
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(nodeColor(for: contact.sentiment))
                            .frame(width: 8, height: 8)
                    }
                    .padding(.vertical, Spacing.xxxSmall)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(contact.name), \(contact.emailCount) emails, sentiment: \(sentimentLabel(contact.sentiment))")
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    // MARK: - Actions

    private func buildAndSimulate() {
        graphLayout.isReady = false
        Task.detached { [emails, senderEmail, graphSize] in
            let layout = GraphLayout()
            layout.buildGraph(from: emails, senderEmail: senderEmail)
            let simSize = CGSize(
                width: max(graphSize.width, 500),
                height: max(graphSize.height, 350)
            )
            layout.runSimulation(iterations: 120, bounds: simSize)
            await MainActor.run {
                graphLayout.nodes = layout.nodes
                graphLayout.edges = layout.edges
                graphLayout.isReady = true
            }
        }
    }

    private func handleTap(at location: CGPoint) {
        let tapRadius: CGFloat = 20
        if let tapped = graphLayout.nodes.first(where: { node in
            let dx = node.position.x - location.x
            let dy = node.position.y - location.y
            return sqrt(dx * dx + dy * dy) < tapRadius
        }) {
            if tapped.isCenterNode {
                selectedNodeID = nil
            } else {
                selectedNodeID = tapped.id
            }
        } else {
            selectedNodeID = nil
        }
    }

    // MARK: - Styling Helpers

    private func nodeColor(for sentiment: Double) -> Color {
        if sentiment > 0.4 {
            return AppColors.success
        } else if sentiment < -0.4 {
            return AppColors.error
        } else {
            return Color.gray
        }
    }

    private func sentimentLabel(_ sentiment: Double) -> String {
        if sentiment > 0.4 { return "Positive" }
        if sentiment < -0.4 { return "Negative" }
        return "Neutral"
    }

    private func shortName(_ name: String) -> String {
        if name.count <= 12 { return name }
        let parts = name.split(separator: " ")
        if parts.count >= 2, let first = parts.first, let second = parts.dropFirst().first {
            return "\(first) \(second.prefix(1))."
        }
        return String(name.prefix(12))
    }
}
