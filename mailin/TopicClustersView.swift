import SwiftUI
import NaturalLanguage

struct TopicClustersView: View {
    let emails: [MBOXParser.RawEmail]
    @State private var clusters: [TopicCluster] = []
    @State private var isComputing = false
    @State private var silhouetteScore: Double?
    @State private var selectedClusterID: UUID?
    @State private var sortOrder: TopicSortOrder = .emailsDesc
    @Binding var selectedClusterFilter: String?
    @Binding var clusterFilterIDs: Set<UUID>?

    enum TopicSortOrder: String, CaseIterable {
        case emailsDesc = "Emails (Most)"
        case emailsAsc = "Emails (Fewest)"
        case nameAZ = "Name (A–Z)"
        case nameZA = "Name (Z–A)"
        case coherenceDesc = "Coherence (High)"
        case coherenceAsc = "Coherence (Low)"
    }

    struct TopicCluster: Identifiable {
        let id = UUID()
        let label: String
        let keywords: [String]
        let emailIDs: [UUID]
        let color: Color
        let coherence: Double
    }

    var body: some View {
        VStack(spacing: 0) {
            if clusters.isEmpty && !isComputing {
                emptyState
            } else if isComputing {
                computingState
            } else {
                clusterContent
            }
        }
        .background(AppColors.backgroundTertiary)
        .onAppear {
            if clusters.isEmpty {
                computeClusters()
            }
        }
    }

    private func qualityBadge(score: Double) -> some View {
        let label = score > 0.5 ? "Excellent" : score > 0.3 ? "Good" : score > 0.15 ? "Fair" : "Low"
        let color: Color = score > 0.5 ? .green : score > 0.3 ? .blue : score > 0.15 ? .orange : .red
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label) · \(String(format: "%.0f%%", score * 100))")
                .font(Typography.caption2)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(CornerRadius.small)
    }

    private var sortedClusters: [TopicCluster] {
        clusters.sorted { a, b in
            switch sortOrder {
            case .emailsDesc:
                return a.emailIDs.count > b.emailIDs.count
            case .emailsAsc:
                return a.emailIDs.count < b.emailIDs.count
            case .nameAZ:
                return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            case .nameZA:
                return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedDescending
            case .coherenceDesc:
                return a.coherence > b.coherence
            case .coherenceAsc:
                return a.coherence < b.coherence
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.medium) {
            Spacer()
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 48))
                .foregroundColor(AppColors.secondary.opacity(0.4))
            Text("Discover Email Topics")
                .font(Typography.title3)
                .fontWeight(.semibold)
            Text("AI-powered clustering groups your emails by topic using natural language processing.")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
            Button {
                computeClusters()
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Analyze Topics")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .padding(Spacing.large)
    }

    // MARK: - Computing State

    private var computingState: some View {
        VStack(spacing: Spacing.medium) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Analyzing email topics...")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
            Text("Using NLP sentence embeddings and k-means++ clustering")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary.opacity(0.7))
            Spacer()
        }
    }

    // MARK: - Cluster Content

    private var clusterContent: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: Spacing.medium)], spacing: Spacing.medium) {
                    ForEach(sortedClusters) { cluster in
                        clusterCard(cluster)
                    }
                }
                .padding(Spacing.medium)
            }

            if selectedClusterFilter != nil {
                filterBar
            }
        }
    }

    private var summaryBar: some View {
        HStack(spacing: Spacing.medium) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "number")
                    .foregroundColor(AppColors.primary)
                Text("\(clusters.count) topics · \(emails.count) emails")
                    .font(Typography.caption1)
                    .fontWeight(.medium)
            }

            if let score = silhouetteScore {
                qualityBadge(score: score)
            }

            Spacer()

            if selectedClusterFilter != nil {
                Button {
                    withAnimation { selectedClusterFilter = nil; selectedClusterID = nil; clusterFilterIDs = nil }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Clear Filter")
                    }
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.error)
                }
                .buttonStyle(.plain)
            }

            Menu {
                ForEach(TopicSortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        HStack {
                            Text(order.rawValue)
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9))
                    Text("Sort")
                        .font(Typography.caption2)
                }
                .foregroundColor(AppColors.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AppColors.primary.opacity(0.1))
                .cornerRadius(CornerRadius.small)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                clusters = []
                silhouetteScore = nil
                selectedClusterFilter = nil
                selectedClusterID = nil
                clusterFilterIDs = nil
                computeClusters()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Re-analyze")
                }
                .font(Typography.caption1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.backgroundSecondary)
    }

    private var filterBar: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundColor(AppColors.primary)
            if let filter = selectedClusterFilter {
                Text("Filtering by: **\(filter)**")
                    .font(Typography.caption1)
            }
            Spacer()
            if let cluster = clusters.first(where: { $0.id == selectedClusterID }) {
                Text("\(cluster.emailIDs.count) email\(cluster.emailIDs.count == 1 ? "" : "s")")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xSmall)
        .background(AppColors.primary.opacity(0.08))
    }

    // MARK: - Cluster Card

    private func clusterCard(_ cluster: TopicCluster) -> some View {
        let isSelected = selectedClusterID == cluster.id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isSelected {
                    selectedClusterFilter = nil
                    selectedClusterID = nil
                    clusterFilterIDs = nil
                } else {
                    selectedClusterFilter = cluster.label
                    selectedClusterID = cluster.id
                    clusterFilterIDs = Set(cluster.emailIDs)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack {
                    Circle()
                        .fill(cluster.color.gradient)
                        .frame(width: 12, height: 12)
                    Text(cluster.label)
                        .font(Typography.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(cluster.color)
                            .font(.system(size: 16))
                    }
                }

                HStack(spacing: Spacing.xxSmall) {
                    ForEach(cluster.keywords.prefix(4), id: \.self) { keyword in
                        Text(keyword)
                            .font(Typography.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(cluster.color.opacity(0.1))
                            .foregroundColor(cluster.color)
                            .cornerRadius(CornerRadius.small)
                    }
                    if cluster.keywords.count > 4 {
                        Text("+\(cluster.keywords.count - 4)")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                }

                Divider()

                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.secondary)
                        Text("\(cluster.emailIDs.count) email\(cluster.emailIDs.count == 1 ? "" : "s")")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                    Spacer()
                    if cluster.coherence > 0 {
                        cohesionIndicator(cluster.coherence, color: cluster.color)
                    }
                }
            }
            .padding(Spacing.small)
            .background(isSelected ? cluster.color.opacity(0.08) : AppColors.backgroundPrimary)
            .cornerRadius(CornerRadius.medium)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .stroke(isSelected ? cluster.color : AppColors.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 0.5)
            )
            .shadow(color: .black.opacity(isSelected ? 0.08 : 0.03), radius: isSelected ? 6 : 2, y: isSelected ? 3 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cluster.label), \(cluster.emailIDs.count) emails")
        .accessibilityHint(isSelected ? "Double tap to deselect" : "Double tap to filter by this topic")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func cohesionIndicator(_ value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppColors.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.6))
                        .frame(width: geo.size.width * min(value, 1.0))
                }
            }
            .frame(width: 40, height: 4)
            Text("\(String(format: "%.0f%%", value * 100))")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
        }
    }

    // MARK: - Compute

    private func computeClusters() {
        isComputing = true
        let allEmails = emails

        Task.detached(priority: .utility) {
            let k = min(8, max(2, allEmails.count / 20))
            let (result, silhouette) = Self.kMeansPlusPlusClustering(emails: allEmails, k: k)
            await MainActor.run {
                self.clusters = result
                self.silhouetteScore = silhouette
                self.isComputing = false
            }
        }
    }

    nonisolated private static let clusterColors: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .indigo]

    // MARK: - k-means++ Clustering

    private nonisolated static let maxClusteringEmails = 10_000

    nonisolated static func kMeansPlusPlusClustering(emails: [MBOXParser.RawEmail], k: Int) -> ([TopicCluster], Double) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return ([], 0) }

        let sampled: [MBOXParser.RawEmail]
        if emails.count > maxClusteringEmails {
            let sorted = emails.sorted { $0.id.uuidString < $1.id.uuidString }
            sampled = Array(sorted.prefix(maxClusteringEmails))
        } else {
            sampled = emails
        }

        var vectors: [(UUID, [Double])] = []
        for email in sampled {
            let text = (email.headers["Subject"] ?? "") + ". " + String(email.plainBody.prefix(300))
            if let vec = embedding.vector(for: text) {
                vectors.append((email.id, vec))
            }
        }
        guard vectors.count >= k else { return ([], 0) }

        let dim = vectors[0].1.count

        var centroids: [[Double]] = []
        var seed: UInt64 = 42
        func nextSeeded() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }

        let firstIdx = abs(nextSeeded()) % vectors.count
        centroids.append(vectors[firstIdx].1)

        for _ in 1..<k {
            var distances = [Double](repeating: 0, count: vectors.count)
            var totalDist = 0.0
            for (i, (_, vec)) in vectors.enumerated() {
                var minDist = Double.infinity
                for c in centroids {
                    let d = squaredEuclidean(vec, c)
                    if d < minDist { minDist = d }
                }
                distances[i] = minDist
                totalDist += minDist
            }

            guard totalDist > 0 else { break }
            let fraction = Double(abs(nextSeeded()) % 1_000_000) / 1_000_000.0
            var target = fraction * totalDist
            var chosen = 0
            for (i, d) in distances.enumerated() {
                target -= d
                if target <= 0 {
                    chosen = i
                    break
                }
            }
            centroids.append(vectors[chosen].1)
        }

        var assignments = [Int](repeating: 0, count: vectors.count)
        let maxIterations = 30
        let convergenceThreshold = 1e-6

        for iteration in 0..<maxIterations {
            for (i, (_, vec)) in vectors.enumerated() {
                var bestCluster = 0
                var bestDist = Double.infinity
                for c in 0..<centroids.count {
                    let dist = squaredEuclidean(vec, centroids[c])
                    if dist < bestDist {
                        bestDist = dist
                        bestCluster = c
                    }
                }
                assignments[i] = bestCluster
            }

            var newCentroids = [[Double]](repeating: [Double](repeating: 0, count: dim), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, (_, vec)) in vectors.enumerated() {
                let c = assignments[i]
                counts[c] += 1
                for d in 0..<dim { newCentroids[c][d] += vec[d] }
            }
            for c in 0..<k {
                if counts[c] > 0 {
                    for d in 0..<dim { newCentroids[c][d] /= Double(counts[c]) }
                } else {
                    newCentroids[c] = centroids[c]
                }
            }

            var shift = 0.0
            for c in 0..<k {
                shift += squaredEuclidean(centroids[c], newCentroids[c])
            }
            centroids = newCentroids

            if iteration > 3 && shift < convergenceThreshold { break }
        }

        var clusterEmails: [[UUID]] = Array(repeating: [], count: k)
        for (i, (id, _)) in vectors.enumerated() {
            clusterEmails[assignments[i]].append(id)
        }

        let silhouette = computeSilhouette(vectors: vectors.map(\.1), assignments: assignments, k: k)

        var clusterCoherences = [Double](repeating: 0, count: k)
        for c in 0..<k {
            let clusterVecs = vectors.enumerated().filter { assignments[$0.offset] == c }.map(\.element.1)
            if clusterVecs.count >= 2 {
                var totalSim = 0.0
                var pairs = 0
                let sampleVecs = clusterVecs.count > 50 ? Array(clusterVecs.prefix(50)) : clusterVecs
                for i in 0..<sampleVecs.count {
                    for j in (i+1)..<sampleVecs.count {
                        totalSim += cosineSimilarity(sampleVecs[i], sampleVecs[j])
                        pairs += 1
                    }
                }
                clusterCoherences[c] = pairs > 0 ? totalSim / Double(pairs) : 0
            }
        }

        let emailMap = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
        var results: [TopicCluster] = []
        for c in 0..<k {
            guard !clusterEmails[c].isEmpty else { continue }
            let clusterEmailObjects = clusterEmails[c].compactMap { emailMap[$0] }
            let keywords = topKeywords(from: clusterEmailObjects, count: 5)
            let label = keywords.prefix(3).joined(separator: ", ").capitalized
            results.append(TopicCluster(
                label: label.isEmpty ? "Cluster \(c+1)" : label,
                keywords: keywords,
                emailIDs: clusterEmails[c],
                color: clusterColors[c % clusterColors.count],
                coherence: clusterCoherences[c]
            ))
        }

        let filtered = results.filter { $0.emailIDs.count >= 2 }
        return (filtered.sorted { $0.emailIDs.count > $1.emailIDs.count }, silhouette)
    }

    // MARK: - Silhouette Score

    nonisolated private static func computeSilhouette(vectors: [[Double]], assignments: [Int], k: Int) -> Double {
        guard vectors.count > k else { return 0 }

        let sampleSize = min(vectors.count, 500)
        let sampleIndices: [Int]
        if vectors.count > sampleSize {
            sampleIndices = Array(0..<vectors.count).shuffled().prefix(sampleSize).sorted()
        } else {
            sampleIndices = Array(0..<vectors.count)
        }

        var totalSilhouette = 0.0
        for idx in sampleIndices {
            let myCluster = assignments[idx]
            var intraSum = 0.0
            var intraCount = 0

            var interSums = [Double](repeating: 0, count: k)
            var interCounts = [Int](repeating: 0, count: k)

            for j in 0..<vectors.count {
                guard j != idx else { continue }
                let dist = euclideanDistance(vectors[idx], vectors[j])
                let c = assignments[j]
                if c == myCluster {
                    intraSum += dist
                    intraCount += 1
                } else {
                    interSums[c] += dist
                    interCounts[c] += 1
                }
            }

            let a = intraCount > 0 ? intraSum / Double(intraCount) : 0
            var b = Double.infinity
            for c in 0..<k where c != myCluster && interCounts[c] > 0 {
                let avg = interSums[c] / Double(interCounts[c])
                if avg < b { b = avg }
            }
            if b == .infinity { b = 0 }

            let s = max(a, b) > 0 ? (b - a) / max(a, b) : 0
            totalSilhouette += s
        }

        guard !sampleIndices.isEmpty else { return 0 }
        return totalSilhouette / Double(sampleIndices.count)
    }

    // MARK: - Distance Metrics

    nonisolated private static func squaredEuclidean(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
    }

    nonisolated private static func euclideanDistance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(squaredEuclidean(a, b))
    }

    nonisolated private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, nA = 0.0, nB = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            nA += a[i] * a[i]
            nB += b[i] * b[i]
        }
        let d = sqrt(nA) * sqrt(nB)
        return d > 0 ? dot / d : 0
    }

    // MARK: - Keyword Extraction

    nonisolated private static func topKeywords(from emails: [MBOXParser.RawEmail], count: Int) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "are", "but", "not", "you", "all", "can", "had",
            "her", "was", "one", "our", "out", "has", "have", "from", "this", "that",
            "with", "your", "will", "been", "they", "them", "then", "than", "each",
            "make", "like", "just", "over", "such", "take", "some", "very", "when",
            "what", "which", "their", "said", "would", "about", "could", "other",
            "into", "more", "also", "back", "after", "only", "come", "made", "good",
            "know", "most", "http", "https", "mailto", "www", "com", "org", "net",
            "sent", "email", "mail", "subject", "message", "wrote", "please", "thank",
            "thanks", "regards", "hello", "dear", "best", "sincerely", "reply",
            "forward", "forwarded", "original", "attachment", "attached",
        ]

        var wordCounts: [String: Int] = [:]
        var docFreq: [String: Int] = [:]
        for email in emails {
            let text = ((email.headers["Subject"] ?? "") + " " + String(email.plainBody.prefix(500))).lowercased()
            let words = text.components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 3 && !stopWords.contains($0) && $0.range(of: #"^\d+$"#, options: .regularExpression) == nil }
            var seen = Set<String>()
            for word in words {
                wordCounts[word, default: 0] += 1
                if seen.insert(word).inserted { docFreq[word, default: 0] += 1 }
            }
        }

        let n = Double(max(emails.count, 1))
        let minFreq = emails.count <= 3 ? 1 : 2
        return wordCounts
            .filter { $0.value >= minFreq }
            .filter { docFreq[$0.key, default: 0] < Int(n * 0.8) + 1 }
            .map { (word: $0.key, tfidf: Double($0.value) * log(n / Double(docFreq[$0.key, default: 1] + 1) + 1)) }
            .sorted { $0.tfidf > $1.tfidf }
            .prefix(count)
            .map(\.word)
    }
}

