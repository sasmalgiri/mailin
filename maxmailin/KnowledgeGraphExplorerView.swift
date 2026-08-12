import SwiftUI

struct KnowledgeGraphExplorerView: View {
    let emails: [MBOXParser.RawEmail]

    @State private var graph = KnowledgeGraph()
    @State private var isBuilding = false
    @State private var hasBuilt = false
    @State private var searchText = ""
    @State private var selectedNodeID: String?
    @State private var selectedTab: KGTab = .overview
    @State private var showTutorial = false

    enum KGTab: String, CaseIterable {
        case overview = "Overview"
        case people = "People"
        case organizations = "Orgs"
        case topics = "Topics"
        case domains = "Domains"
        case explore = "Explore"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isBuilding {
                buildingIndicator
            } else if !hasBuilt {
                buildPrompt
            } else {
                tabBar
                graphContent
            }
        }
        .background(AppColors.backgroundPrimary)
        .task { loadExistingGraph() }
        .featureTutorial(.knowledgeGraph, key: "knowledge_graph_tutorial_seen", isPresented: $showTutorial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.linearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 2) {
                Text("Knowledge Graph")
                    .font(.system(.title3, design: .rounded)).fontWeight(.bold)
                if hasBuilt {
                    Text("\(graph.nodeCount) nodes · \(graph.edgeCount) edges")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if hasBuilt {
                Button { Task { await rebuildGraph() } } label: {
                    Label("Rebuild", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).fontWeight(.medium)
                }
                .buttonStyle(.bordered)
            }
            SaveToDocumentsButton(title: "Knowledge Graph") {
                [.init(key: "Emails", value: "\(emails.count)")]
            }
            TutorialHelpButton(showTutorial: $showTutorial)
        }
        .padding(Spacing.medium)
    }

    // MARK: - Build States

    private var buildingIndicator: some View {
        VStack(spacing: Spacing.medium) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Building knowledge graph from \(emails.count) emails...")
                .font(.subheadline).foregroundColor(.secondary)
            Text("Extracting people, organizations, topics, and relationships")
                .font(.caption).foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
    }

    private var buildPrompt: some View {
        VStack(spacing: Spacing.large) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.linearGradient(colors: [.purple.opacity(0.5), .blue.opacity(0.5)], startPoint: .top, endPoint: .bottom))

            Text("Build Knowledge Graph")
                .font(.system(.title2, design: .rounded)).fontWeight(.bold)
            Text("Analyze \(emails.count) emails to discover people, organizations, topics, and their relationships.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button { Task { await rebuildGraph() } } label: {
                Label("Build Graph", systemImage: "sparkles")
                    .font(.headline)
                    .padding(.horizontal, Spacing.large)
                    .padding(.vertical, Spacing.small)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            Spacer()
        }
        .padding(Spacing.large)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xSmall) {
                ForEach(KGTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                            .foregroundColor(selectedTab == tab ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedTab == tab ? Capsule().fill(.purple) : Capsule().fill(.purple.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.xSmall)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var graphContent: some View {
        switch selectedTab {
        case .overview: overviewTab
        case .people: nodeListTab(type: .person, icon: "person.fill", color: .blue)
        case .organizations: nodeListTab(type: .organization, icon: "building.2.fill", color: .orange)
        case .topics: nodeListTab(type: .topic, icon: "text.bubble.fill", color: .teal)
        case .domains: nodeListTab(type: .domain, icon: "globe", color: .green)
        case .explore: exploreTab
        }
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        ScrollView {
            VStack(spacing: Spacing.medium) {
                statsGrid
                topPeopleSection
                topTopicsSection
                strongestConnectionsSection
            }
            .padding(Spacing.medium)
        }
    }

    private var statsGrid: some View {
        let stats = graph.statistics()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.small), count: 3), spacing: Spacing.small) {
            statCard("People", "\(stats.people)", "person.fill", .blue)
            statCard("Organizations", "\(stats.orgs)", "building.2.fill", .orange)
            statCard("Topics", "\(stats.topics)", "text.bubble.fill", .teal)
            statCard("Domains", "\(stats.domains)", "globe", .green)
            statCard("Emails", "\(stats.emails)", "envelope.fill", .purple)
            statCard("Relationships", "\(stats.edges)", "link", .pink)
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: Spacing.xSmall) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
            Text(value)
                .font(.system(.title2, design: .rounded)).fontWeight(.bold)
            Text(title)
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.small)
        .background(RoundedRectangle(cornerRadius: CornerRadius.medium).fill(color.opacity(0.06)))
    }

    private var topPeopleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader("Top People", icon: "person.fill", color: .blue)
            ForEach(graph.topNodes(by: .person, limit: 8), id: \.id) { node in
                nodeRow(node, color: .blue)
            }
        }
        .padding(Spacing.medium)
        .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(AppColors.backgroundSecondary))
    }

    private var topTopicsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader("Top Topics", icon: "text.bubble.fill", color: .teal)
            ForEach(graph.topNodes(by: .topic, limit: 8), id: \.id) { node in
                nodeRow(node, color: .teal)
            }
        }
        .padding(Spacing.medium)
        .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(AppColors.backgroundSecondary))
    }

    private var strongestConnectionsSection: some View {
        let topEdges = graph.allEdges.sorted { $0.weight > $1.weight }.prefix(10)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader("Strongest Connections", icon: "link", color: .pink)
            ForEach(Array(topEdges), id: \.id) { edge in
                HStack(spacing: Spacing.xSmall) {
                    Text(graph.findNode(id: edge.sourceID)?.label ?? edge.sourceID)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(graph.findNode(id: edge.targetID)?.label ?? edge.targetID)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(edge.type.rawValue)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.purple.opacity(0.1)))
                    Text("×\(Int(edge.weight))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.pink)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(Spacing.medium)
        .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(AppColors.backgroundSecondary))
    }

    // MARK: - Node List Tab

    private func nodeListTab(type: KGNodeType, icon: String, color: Color) -> some View {
        let allNodes = graph.findNodes(type: type).sorted { $0.weight > $1.weight }
        let filtered = searchText.isEmpty ? allNodes : allNodes.filter {
            $0.label.localizedCaseInsensitiveContains(searchText) ||
            $0.properties.values.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }

        return VStack(spacing: 0) {
            searchBar
            ScrollView {
                LazyVStack(spacing: Spacing.xxSmall) {
                    ForEach(filtered, id: \.id) { node in
                        Button {
                            selectedNodeID = node.id
                            selectedTab = .explore
                        } label: {
                            nodeRow(node, color: color)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.medium)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search nodes...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.small)
        .background(RoundedRectangle(cornerRadius: CornerRadius.medium).fill(AppColors.backgroundSecondary))
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xSmall)
    }

    // MARK: - Explore Tab

    private var exploreTab: some View {
        VStack(spacing: 0) {
            searchBar
            if let nodeID = selectedNodeID, let node = graph.findNode(id: nodeID) {
                nodeDetailView(node)
            } else {
                VStack(spacing: Spacing.medium) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Search for a node or tap one from the list tabs")
                        .font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.isEmpty {
                let results = graph.findNodes(matching: newValue)
                if let first = results.first { selectedNodeID = first.id }
            }
        }
    }

    private func nodeDetailView(_ node: KGNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack(spacing: Spacing.small) {
                    Image(systemName: iconForType(node.type))
                        .font(.title2)
                        .foregroundColor(colorForType(node.type))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.label)
                            .font(.system(.title3, design: .rounded)).fontWeight(.bold)
                        HStack(spacing: Spacing.xSmall) {
                            Text(node.type.rawValue.capitalized)
                                .font(.caption).fontWeight(.medium)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(colorForType(node.type).opacity(0.15)))
                            Text("Weight: \(String(format: "%.0f", node.weight))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                if !node.properties.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text("Properties").font(.headline)
                        ForEach(node.properties.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack {
                                Text(key).font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                                Spacer()
                                Text(value).font(.caption).lineLimit(1)
                            }
                        }
                    }
                    .padding(Spacing.small)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.medium).fill(AppColors.backgroundSecondary))
                }

                let neighborNodes = graph.neighbors(of: node.id)
                if !neighborNodes.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text("Connections (\(neighborNodes.count))").font(.headline)
                        let grouped = Dictionary(grouping: neighborNodes) { $0.type }
                        ForEach(KGNodeType.allCases, id: \.self) { type in
                            if let nodes = grouped[type], !nodes.isEmpty {
                                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                                    Text(type.rawValue.capitalized + "s")
                                        .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                                    ForEach(nodes.sorted { $0.weight > $1.weight }.prefix(15), id: \.id) { neighbor in
                                        Button {
                                            selectedNodeID = neighbor.id
                                        } label: {
                                            nodeRow(neighbor, color: colorForType(neighbor.type))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(Spacing.small)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.medium).fill(AppColors.backgroundSecondary))
                }
            }
            .padding(Spacing.medium)
        }
    }

    // MARK: - Components

    private func nodeRow(_ node: KGNode, color: Color) -> some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: iconForType(node.type))
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let email = node.properties["email"] {
                    Text(email).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            let neighborCount = graph.neighbors(of: node.id).count
            if neighborCount > 0 {
                Text("\(neighborCount)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.08)))
            }
            Text("×\(Int(node.weight))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: Spacing.xxSmall) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
            Text(title)
                .font(.system(.headline, design: .rounded))
        }
    }

    private func iconForType(_ type: KGNodeType) -> String {
        switch type {
        case .person: return "person.fill"
        case .organization: return "building.2.fill"
        case .topic: return "text.bubble.fill"
        case .email: return "envelope.fill"
        case .domain: return "globe"
        }
    }

    private func colorForType(_ type: KGNodeType) -> Color {
        switch type {
        case .person: return .blue
        case .organization: return .orange
        case .topic: return .teal
        case .email: return .purple
        case .domain: return .green
        }
    }

    // MARK: - Actions

    private func loadExistingGraph() {
        let loaded = KnowledgeGraph.load()
        if loaded.nodeCount > 0 {
            graph = loaded
            hasBuilt = true
        }
    }

    private func rebuildGraph() async {
        isBuilding = true
        let newGraph = KnowledgeGraph()
        let emailsCopy = emails
        await Task.detached(priority: .userInitiated) {
            KnowledgeGraphBuilder.build(from: emailsCopy, into: newGraph)
            newGraph.save()
        }.value
        graph = newGraph
        hasBuilt = true
        isBuilding = false
    }
}
