//
//  AIVisualizationGenerator.swift
//  mailin
//
//  AI-driven visualization data generation: topic flows, heatmaps, sentiment timelines,
//  and relationship map annotations powered by KnowledgeGraph + NLP.
//

import Foundation
import SwiftUI
import NaturalLanguage

// MARK: - Visualization Type

enum VisualizationType: String, CaseIterable, Identifiable {
    case topicFlow
    case communicationHeatmap
    case sentimentTimeline
    case relationshipMap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topicFlow: return "Topic Flow"
        case .communicationHeatmap: return "Activity Heatmap"
        case .sentimentTimeline: return "Sentiment Timeline"
        case .relationshipMap: return "Relationship Map"
        }
    }

    var icon: String {
        switch self {
        case .topicFlow: return "chart.line.uptrend.xyaxis"
        case .communicationHeatmap: return "square.grid.3x3.fill"
        case .sentimentTimeline: return "waveform.path.ecg"
        case .relationshipMap: return "person.3.fill"
        }
    }
}

// MARK: - Topic Flow Data

struct TopicFlowData {
    struct TopicPeriod: Identifiable {
        let id = UUID()
        let period: String
        let topic: String
        let count: Int
        let normalizedWeight: Double
    }

    let topics: [String]
    let periods: [String]
    let data: [TopicPeriod]

    static func generate(from emails: [MBOXParser.RawEmail]) -> TopicFlowData {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"

        var periodTopicCounts: [String: [String: Int]] = [:]
        var allPeriods: Set<String> = []

        let topTopics = EmailNLPEngine.extractTopics(from: emails, limit: 8).map { $0.word.lowercased() }
        guard !topTopics.isEmpty else {
            return TopicFlowData(topics: [], periods: [], data: [])
        }

        for email in emails {
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }
            let components = cal.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { continue }
            let period = "\(year)-\(String(format: "%02d", month))"
            allPeriods.insert(period)

            let text = ((email.headers["Subject"] ?? "") + " " + String(email.plainBody.prefix(300))).lowercased()
            for topic in topTopics {
                if text.contains(topic) {
                    periodTopicCounts[period, default: [:]][topic, default: 0] += 1
                }
            }
        }

        let sortedPeriods = allPeriods.sorted()
        let maxCount = periodTopicCounts.values.flatMap(\.values).max() ?? 1

        var data: [TopicPeriod] = []
        for period in sortedPeriods {
            let counts = periodTopicCounts[period] ?? [:]
            for topic in topTopics {
                let count = counts[topic] ?? 0
                data.append(TopicPeriod(
                    period: period,
                    topic: topic,
                    count: count,
                    normalizedWeight: Double(count) / Double(maxCount)
                ))
            }
        }

        return TopicFlowData(topics: topTopics, periods: sortedPeriods, data: data)
    }
}

// MARK: - Communication Heatmap Data

struct CommunicationHeatmapData {
    struct Cell: Identifiable {
        let id = UUID()
        let dayOfWeek: Int
        let hour: Int
        let count: Int
        let normalizedIntensity: Double
    }

    let cells: [Cell]
    let maxCount: Int
    let totalEmails: Int

    static let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let hourLabels: [String] = (0..<24).map { h in
        h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p"
    }

    static func generate(from emails: [MBOXParser.RawEmail]) -> CommunicationHeatmapData {
        let cal = Calendar.current
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)

        for email in emails {
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }
            let weekday = cal.component(.weekday, from: date) - 1
            let hour = cal.component(.hour, from: date)
            if weekday >= 0 && weekday < 7 && hour >= 0 && hour < 24 {
                grid[weekday][hour] += 1
            }
        }

        let maxVal = grid.flatMap { $0 }.max() ?? 1
        var cells: [Cell] = []
        for day in 0..<7 {
            for hour in 0..<24 {
                let count = grid[day][hour]
                cells.append(Cell(
                    dayOfWeek: day,
                    hour: hour,
                    count: count,
                    normalizedIntensity: maxVal > 0 ? Double(count) / Double(maxVal) : 0
                ))
            }
        }

        return CommunicationHeatmapData(
            cells: cells,
            maxCount: maxVal,
            totalEmails: emails.count
        )
    }
}

// MARK: - Sentiment Timeline Data

struct SentimentTimelineData {
    struct DataPoint: Identifiable {
        let id = UUID()
        let period: String
        let averageSentiment: Double
        let emailCount: Int
        let positiveCount: Int
        let negativeCount: Int
    }

    let dataPoints: [DataPoint]

    static func generate(from emails: [MBOXParser.RawEmail]) -> SentimentTimelineData {
        let cal = Calendar.current
        var periodEmails: [String: [MBOXParser.RawEmail]] = [:]

        for email in emails {
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }
            let components = cal.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { continue }
            let period = "\(year)-\(String(format: "%02d", month))"
            periodEmails[period, default: []].append(email)
        }

        let sorted = periodEmails.sorted { $0.key < $1.key }
        var dataPoints: [DataPoint] = []

        for (period, pEmails) in sorted {
            let sentimentResults = EmailNLPEngine.analyzeSentiment(of: pEmails)
            let avg = sentimentResults.isEmpty ? 0 : sentimentResults.map(\.score).reduce(0, +) / Double(sentimentResults.count)
            let posCount = sentimentResults.filter { $0.score > 0.2 }.count
            let negCount = sentimentResults.filter { $0.score < -0.2 }.count

            dataPoints.append(DataPoint(
                period: period,
                averageSentiment: avg,
                emailCount: pEmails.count,
                positiveCount: posCount,
                negativeCount: negCount
            ))
        }

        return SentimentTimelineData(dataPoints: dataPoints)
    }
}

// MARK: - Relationship Map Annotation

struct RelationshipMapAnnotation: Identifiable {
    let id = UUID()
    let nodeID: String
    let label: String
    let annotation: String
    let importance: Double
    let annotationType: AnnotationType

    enum AnnotationType {
        case keyConnector
        case topicExpert
        case sentimentOutlier
        case highVolume
        case recentActive
    }
}

// MARK: - AI Visualization Generator

struct AIVisualizationGenerator {

    static func recommendVisualization(for query: String) -> VisualizationType {
        let lower = query.lowercased()

        let topicKeywords = ["topic", "subject", "theme", "discussion", "talked about", "content", "flow"]
        let heatmapKeywords = ["when", "time", "hour", "day", "schedule", "pattern", "activity", "busy", "active"]
        let sentimentKeywords = ["sentiment", "mood", "tone", "feeling", "emotion", "positive", "negative", "happy", "angry"]
        let relationshipKeywords = ["relationship", "contact", "network", "who", "person", "people", "connect", "communicate"]

        var scores: [VisualizationType: Int] = [:]
        for kw in topicKeywords where lower.contains(kw) { scores[.topicFlow, default: 0] += 1 }
        for kw in heatmapKeywords where lower.contains(kw) { scores[.communicationHeatmap, default: 0] += 1 }
        for kw in sentimentKeywords where lower.contains(kw) { scores[.sentimentTimeline, default: 0] += 1 }
        for kw in relationshipKeywords where lower.contains(kw) { scores[.relationshipMap, default: 0] += 1 }

        if let best = scores.max(by: { $0.value < $1.value }), best.value > 0 {
            return best.key
        }

        return .communicationHeatmap
    }

    static func annotateRelationshipMap(
        emails: [MBOXParser.RawEmail],
        graph: KnowledgeGraph
    ) -> [RelationshipMapAnnotation] {
        var annotations: [RelationshipMapAnnotation] = []

        let topPeople = graph.topNodes(by: .person, limit: 20)
        let maxWeight = topPeople.first?.weight ?? 1

        for person in topPeople {
            let neighbors = graph.neighbors(of: person.id)
            let topics = neighbors.filter { $0.type == .topic }
            let connections = neighbors.filter { $0.type == .person }

            if connections.count >= 5 {
                annotations.append(RelationshipMapAnnotation(
                    nodeID: person.properties["email"] ?? person.id,
                    label: person.label,
                    annotation: "Key connector — linked to \(connections.count) people",
                    importance: min(1.0, Double(connections.count) / 10.0),
                    annotationType: .keyConnector
                ))
            }

            if !topics.isEmpty {
                let topTopics = topics.sorted { $0.weight > $1.weight }.prefix(2).map(\.label)
                annotations.append(RelationshipMapAnnotation(
                    nodeID: person.properties["email"] ?? person.id,
                    label: person.label,
                    annotation: "Discusses: \(topTopics.joined(separator: ", "))",
                    importance: 0.5,
                    annotationType: .topicExpert
                ))
            }

            if person.weight > maxWeight * 0.7 {
                annotations.append(RelationshipMapAnnotation(
                    nodeID: person.properties["email"] ?? person.id,
                    label: person.label,
                    annotation: "High volume — \(Int(person.weight)) interactions",
                    importance: person.weight / maxWeight,
                    annotationType: .highVolume
                ))
            }
        }

        let personEmails = Dictionary(grouping: emails) { email -> String in
            let from = email.headers["From"] ?? ""
            return extractEmail(from: from).lowercased()
        }

        for (addr, pEmails) in personEmails {
            let sentiment = EmailNLPEngine.averageSentiment(of: pEmails)
            if sentiment.average < -0.3 || sentiment.average > 0.5 {
                let label = sentiment.average > 0 ? "Positive tone" : "Negative tone"
                annotations.append(RelationshipMapAnnotation(
                    nodeID: addr,
                    label: addr,
                    annotation: "\(label) (\(String(format: "%.1f", sentiment.average)))",
                    importance: abs(sentiment.average),
                    annotationType: .sentimentOutlier
                ))
            }
        }

        annotations.sort { $0.importance > $1.importance }
        return Array(annotations.prefix(30))
    }

    private static func extractEmail(from field: String) -> String {
        if let start = field.firstIndex(of: "<"),
           let end = field.firstIndex(of: ">"),
           start < end {
            return String(field[field.index(after: start)..<end])
        }
        return field.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Topic Flow Chart View

struct TopicFlowChartView: View {
    let data: TopicFlowData

    private let topicColors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .red]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Topic Flow Over Time")
                .font(Typography.headline)

            if data.periods.isEmpty {
                Text("Not enough data for topic flow analysis.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        legendRow
                        chartCanvas
                    }
                    .padding(Spacing.small)
                }

                periodLabels
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private var legendRow: some View {
        HStack(spacing: Spacing.small) {
            ForEach(Array(data.topics.enumerated()), id: \.offset) { idx, topic in
                HStack(spacing: Spacing.xxxSmall) {
                    Circle()
                        .fill(topicColors[idx % topicColors.count])
                        .frame(width: 8, height: 8)
                    Text(topic)
                        .font(Typography.caption2)
                        .lineLimit(1)
                }
            }
        }
    }

    private var chartCanvas: some View {
        Canvas { context, size in
            let periodCount = data.periods.count
            guard periodCount > 1 else { return }

            let barGroupWidth = size.width / CGFloat(periodCount)
            let barWidth = max(2, (barGroupWidth - 4) / CGFloat(data.topics.count))
            let maxHeight = size.height - 20

            for (periodIdx, period) in data.periods.enumerated() {
                let periodData = data.data.filter { $0.period == period }
                for (topicIdx, topic) in data.topics.enumerated() {
                    guard let item = periodData.first(where: { $0.topic == topic }) else { continue }
                    let barHeight = maxHeight * item.normalizedWeight
                    let x = CGFloat(periodIdx) * barGroupWidth + CGFloat(topicIdx) * barWidth + 2
                    let y = size.height - barHeight
                    let rect = CGRect(x: x, y: y, width: barWidth - 1, height: barHeight)
                    let color = topicColors[topicIdx % topicColors.count]
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                }
            }
        }
        .frame(width: max(300, CGFloat(data.periods.count) * 80), height: 180)
    }

    private var periodLabels: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(data.periods, id: \.self) { period in
                    Text(shortPeriod(period))
                        .font(.system(size: 9))
                        .foregroundColor(AppColors.secondary)
                        .frame(width: 80)
                }
            }
            .padding(.horizontal, Spacing.small)
        }
    }

    private func shortPeriod(_ p: String) -> String {
        let parts = p.split(separator: "-")
        guard parts.count == 2 else { return p }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if let m = Int(parts[1]), m > 0, m < months.count {
            return "\(months[m]) '\(parts[0].suffix(2))"
        }
        return p
    }
}

// MARK: - Communication Heatmap View

struct CommunicationHeatmapView: View {
    let data: CommunicationHeatmapData

    private let cellSize: CGFloat = 18
    private let labelWidth: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Activity Heatmap")
                .font(Typography.headline)

            if data.totalEmails == 0 {
                Text("No email data available.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        hourHeaderRow
                        ForEach(0..<7, id: \.self) { day in
                            dayRow(day: day)
                        }
                    }
                    .padding(Spacing.small)
                }

                intensityLegend
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private var hourHeaderRow: some View {
        HStack(spacing: 2) {
            Text("")
                .frame(width: labelWidth)
            ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { hour in
                Text(CommunicationHeatmapData.hourLabels[hour])
                    .font(.system(size: 8))
                    .foregroundColor(AppColors.secondary)
                    .frame(width: cellSize * 3 + 4, alignment: .leading)
            }
        }
    }

    private func dayRow(day: Int) -> some View {
        HStack(spacing: 2) {
            Text(CommunicationHeatmapData.dayLabels[day])
                .font(.system(size: 10))
                .foregroundColor(AppColors.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            ForEach(0..<24, id: \.self) { hour in
                let cell = data.cells.first { $0.dayOfWeek == day && $0.hour == hour }
                let intensity = cell?.normalizedIntensity ?? 0
                RoundedRectangle(cornerRadius: 2)
                    .fill(heatColor(intensity: intensity))
                    .frame(width: cellSize, height: cellSize)
                    .accessibilityLabel("\(CommunicationHeatmapData.dayLabels[day]) \(CommunicationHeatmapData.hourLabels[hour]): \(cell?.count ?? 0) emails")
            }
        }
    }

    private var intensityLegend: some View {
        HStack(spacing: Spacing.xSmall) {
            Text("Less")
                .font(.system(size: 9))
                .foregroundColor(AppColors.secondary)
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { intensity in
                RoundedRectangle(cornerRadius: 2)
                    .fill(heatColor(intensity: intensity))
                    .frame(width: 14, height: 14)
            }
            Text("More")
                .font(.system(size: 9))
                .foregroundColor(AppColors.secondary)
            Spacer()
            Text("Peak: \(data.maxCount) emails")
                .font(.system(size: 9))
                .foregroundColor(AppColors.secondary)
        }
    }

    private func heatColor(intensity: Double) -> Color {
        if intensity <= 0 { return Color.gray.opacity(0.1) }
        return Color.green.opacity(0.15 + intensity * 0.85)
    }
}

// MARK: - Sentiment Timeline View

struct SentimentTimelineView: View {
    let data: SentimentTimelineData

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Sentiment Timeline")
                .font(Typography.headline)

            if data.dataPoints.isEmpty {
                Text("Not enough data for sentiment analysis.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                sentimentChart
                sentimentStats
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private var sentimentChart: some View {
        VStack(spacing: Spacing.xxSmall) {
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let midY = height / 2

                Canvas { context, size in
                    let count = data.dataPoints.count
                    guard count > 1 else { return }

                    let stepX = size.width / CGFloat(count - 1)
                    let scaleY = size.height / 2 * 0.8

                    var zeroPath = Path()
                    zeroPath.move(to: CGPoint(x: 0, y: midY))
                    zeroPath.addLine(to: CGPoint(x: size.width, y: midY))
                    context.stroke(zeroPath, with: .color(.gray.opacity(0.3)), lineWidth: 1)

                    var linePath = Path()
                    var fillPath = Path()
                    for (idx, point) in data.dataPoints.enumerated() {
                        let x = CGFloat(idx) * stepX
                        let y = midY - CGFloat(point.averageSentiment) * scaleY
                        if idx == 0 {
                            linePath.move(to: CGPoint(x: x, y: y))
                            fillPath.move(to: CGPoint(x: x, y: midY))
                            fillPath.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            linePath.addLine(to: CGPoint(x: x, y: y))
                            fillPath.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    fillPath.addLine(to: CGPoint(x: CGFloat(count - 1) * stepX, y: midY))
                    fillPath.closeSubpath()

                    context.fill(fillPath, with: .color(.blue.opacity(0.1)))
                    context.stroke(linePath, with: .color(.blue), lineWidth: 2)

                    for (idx, point) in data.dataPoints.enumerated() {
                        let x = CGFloat(idx) * stepX
                        let y = midY - CGFloat(point.averageSentiment) * scaleY
                        let color: Color = point.averageSentiment > 0.2 ? .green : point.averageSentiment < -0.2 ? .red : .gray
                        let rect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                    }

                    context.draw(Text("+1").font(.system(size: 8)).foregroundColor(.secondary), at: CGPoint(x: size.width - 12, y: 10))
                    context.draw(Text("0").font(.system(size: 8)).foregroundColor(.secondary), at: CGPoint(x: size.width - 8, y: midY))
                    context.draw(Text("-1").font(.system(size: 8)).foregroundColor(.secondary), at: CGPoint(x: size.width - 10, y: size.height - 10))
                }
                .frame(width: width, height: height)
            }
            .frame(height: 160)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(data.dataPoints) { point in
                        Text(shortPeriod(point.period))
                            .font(.system(size: 8))
                            .foregroundColor(AppColors.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var sentimentStats: some View {
        let allSentiments = data.dataPoints.map(\.averageSentiment)
        let avgAll = allSentiments.isEmpty ? 0 : allSentiments.reduce(0, +) / Double(allSentiments.count)
        let trend: String = {
            guard data.dataPoints.count >= 2 else { return "Stable" }
            let recent = data.dataPoints.suffix(3).map(\.averageSentiment).reduce(0, +) / Double(min(3, data.dataPoints.count))
            let older = data.dataPoints.prefix(3).map(\.averageSentiment).reduce(0, +) / Double(min(3, data.dataPoints.count))
            let delta = recent - older
            if delta > 0.15 { return "Improving" }
            if delta < -0.15 { return "Declining" }
            return "Stable"
        }()

        return HStack(spacing: Spacing.medium) {
            miniStat(label: "Average", value: String(format: "%.2f", avgAll))
            miniStat(label: "Trend", value: trend)
            miniStat(label: "Periods", value: "\(data.dataPoints.count)")
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
            Text(value)
                .font(Typography.callout)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
    }

    private func shortPeriod(_ p: String) -> String {
        let parts = p.split(separator: "-")
        guard parts.count == 2 else { return p }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if let m = Int(parts[1]), m > 0, m < months.count {
            return "\(months[m]) '\(parts[0].suffix(2))"
        }
        return p
    }
}

// MARK: - AI Visualization Dashboard View

struct AIVisualizationDashboardView: View {
    let emails: [MBOXParser.RawEmail]

    @State private var selectedType: VisualizationType = .communicationHeatmap
    @State private var topicFlowData: TopicFlowData?
    @State private var heatmapData: CommunicationHeatmapData?
    @State private var sentimentData: SentimentTimelineData?
    @State private var annotations: [RelationshipMapAnnotation]?
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(spacing: Spacing.large) {
                    typePicker
                    visualizationContent
                }
                .padding(Spacing.large)
            }
        }
        .onAppear { loadData() }
        #if os(macOS)
        .toolWindowFrame()
        #endif
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text("AI Visual Reports")
                    .font(Typography.title3)
                Text("\(emails.count) emails analyzed")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.medium)
    }

    private var typePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.small) {
                ForEach(VisualizationType.allCases) { type in
                    Button {
                        selectedType = type
                        loadData()
                    } label: {
                        Label(type.title, systemImage: type.icon)
                            .font(Typography.caption1)
                            .fontWeight(selectedType == type ? .semibold : .regular)
                            .padding(.horizontal, Spacing.small)
                            .padding(.vertical, Spacing.xSmall)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedType == type ? .accentColor : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var visualizationContent: some View {
        if isLoading {
            ProgressView("Generating visualization...")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            switch selectedType {
            case .topicFlow:
                if let data = topicFlowData {
                    TopicFlowChartView(data: data)
                }
            case .communicationHeatmap:
                if let data = heatmapData {
                    CommunicationHeatmapView(data: data)
                }
            case .sentimentTimeline:
                if let data = sentimentData {
                    SentimentTimelineView(data: data)
                }
            case .relationshipMap:
                if let anns = annotations, !anns.isEmpty {
                    annotationsList(anns)
                } else {
                    Text("No relationship annotations available. Import emails and build the knowledge graph first.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
        }
    }

    private func annotationsList(_ anns: [RelationshipMapAnnotation]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Relationship Annotations")
                .font(Typography.headline)

            ForEach(anns) { ann in
                HStack(spacing: Spacing.small) {
                    Image(systemName: annotationIcon(ann.annotationType))
                        .foregroundColor(annotationColor(ann.annotationType))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ann.label)
                            .font(Typography.callout)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(ann.annotation)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    importanceBadge(ann.importance)
                }
                .padding(Spacing.small)
                .adaptiveCard(cornerRadius: CornerRadius.medium)
            }
        }
    }

    private func annotationIcon(_ type: RelationshipMapAnnotation.AnnotationType) -> String {
        switch type {
        case .keyConnector: return "point.3.connected.trianglepath.dotted"
        case .topicExpert: return "text.bubble"
        case .sentimentOutlier: return "heart.fill"
        case .highVolume: return "chart.bar.fill"
        case .recentActive: return "clock.fill"
        }
    }

    private func annotationColor(_ type: RelationshipMapAnnotation.AnnotationType) -> Color {
        switch type {
        case .keyConnector: return .purple
        case .topicExpert: return .blue
        case .sentimentOutlier: return .pink
        case .highVolume: return .orange
        case .recentActive: return .green
        }
    }

    private func importanceBadge(_ importance: Double) -> some View {
        Text(String(format: "%.0f%%", importance * 100))
            .font(.system(size: 10))
            .fontWeight(.semibold)
            .foregroundColor(importance > 0.7 ? AppColors.error : importance > 0.4 ? AppColors.warning : AppColors.secondary)
            .glassBadge()
    }

    private func loadData() {
        isLoading = true
        let emailsCopy = emails
        Task.detached {
            switch await MainActor.run(body: { selectedType }) {
            case .topicFlow:
                let result = TopicFlowData.generate(from: emailsCopy)
                await MainActor.run { topicFlowData = result; isLoading = false }
            case .communicationHeatmap:
                let result = CommunicationHeatmapData.generate(from: emailsCopy)
                await MainActor.run { heatmapData = result; isLoading = false }
            case .sentimentTimeline:
                let result = SentimentTimelineData.generate(from: emailsCopy)
                await MainActor.run { sentimentData = result; isLoading = false }
            case .relationshipMap:
                let graph = KnowledgeGraph.load()
                let result = AIVisualizationGenerator.annotateRelationshipMap(emails: emailsCopy, graph: graph)
                await MainActor.run { annotations = result; isLoading = false }
            }
        }
    }
}
