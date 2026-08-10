import SwiftUI

struct PredictiveCodingView: View {
    let emails: [MBOXParser.RawEmail]
    @ObservedObject var engine: PredictiveCodingEngine
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss
    @State private var initialized = false
    @State private var showTutorial = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statsBar
            Divider()
            emailList
        }
        .featureTutorial(.predictiveCoding, key: "predictive_coding_tutorial_seen", isPresented: $showTutorial)
        .onAppear {
            if !initialized {
                engine.buildVectors(from: emails)
                initialized = true
                // Part K: show PERSISTED model scores for the visible working
                // set immediately — no retraining needed on reopen.
                let visibleIDs = emails.map(\.id)
                Task { await engine.hydratePersistedScores(for: visibleIDs) }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label("Predictive Coding (TAR)", systemImage: "brain.head.profile")
                    .font(Typography.title2)
                Text("Tag emails as relevant or irrelevant. The system learns your pattern and predicts relevance for unreviewed emails.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            if engine.isTraining {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, Spacing.small)
                    .accessibilityLabel("Training predictive model")
            }
            TutorialHelpButton(showTutorial: $showTutorial)
            if isPresented != nil {
                Button { closeSheet() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close predictive coding")
            }
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private var statsBar: some View {
        HStack(spacing: Spacing.large) {
            StatPill(label: "Relevant", count: engine.relevantIDs.count, color: .green)
            StatPill(label: "Irrelevant", count: engine.irrelevantIDs.count, color: .red)
            StatPill(label: "Predicted", count: engine.predictions.count, color: .blue)
            StatPill(label: "Suggested", count: engine.suggestedForReview.count, color: .orange)
        }
        .padding(Spacing.small)
        .background(AppColors.backgroundSecondary)
    }

    private var emailList: some View {
        List {
            if !engine.suggestedForReview.isEmpty {
                Section("AI Suggests Reviewing Next") {
                    ForEach(engine.suggestedForReview, id: \.self) { id in
                        if let email = emails.first(where: { $0.id == id }) {
                            emailRow(email: email, score: engine.predictionScore(for: id))
                        }
                    }
                }
            }

            Section("All Emails (\(emails.count))") {
                ForEach(emails, id: \.id) { email in
                    emailRow(email: email, score: engine.predictionScore(for: email.id))
                }
            }
        }
    }

    private func emailRow(email: MBOXParser.RawEmail, score: Double?) -> some View {
        HStack(spacing: Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(email.headers["Subject"] ?? "(No Subject)")
                    .font(Typography.callout)
                    .lineLimit(1)
                Text(email.headers["From"] ?? "")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let label = engine.predictionLabel(for: email.id) {
                Text(label)
                    .font(Typography.caption2)
                    .padding(.horizontal, Spacing.xxSmall)
                    .padding(.vertical, 2)
                    .background(predictionColor(for: score).opacity(0.15))
                    .foregroundColor(predictionColor(for: score))
                    .cornerRadius(CornerRadius.small)
                    .accessibilityLabel("Prediction: \(label)")
                    .accessibilityValue(score.map { "Confidence \(Int($0 * 100)) percent" } ?? "")
            }

            if engine.relevantIDs.contains(email.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .accessibilityLabel("Tagged as relevant")
            } else if engine.irrelevantIDs.contains(email.id) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .accessibilityLabel("Tagged as irrelevant")
            }

            Button {
                engine.tagRelevant(email.id)
            } label: {
                Image(systemName: "hand.thumbsup")
                    .foregroundColor(.green)
            }
            .buttonStyle(.plain)
            .help("Tag as Relevant")
            .accessibilityLabel("Tag as relevant")

            Button {
                engine.tagIrrelevant(email.id)
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Tag as Irrelevant")
            .accessibilityLabel("Tag as irrelevant")

            if engine.relevantIDs.contains(email.id) || engine.irrelevantIDs.contains(email.id) {
                Button {
                    engine.removeTag(email.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove tag")
                .accessibilityLabel("Remove relevance tag")
            }
        }
        .padding(.vertical, Spacing.xxxSmall)
    }

    private func predictionColor(for score: Double?) -> Color {
        guard let s = score else { return .secondary }
        if s > 0.7 { return .green }
        if s < 0.3 { return .red }
        return .orange
    }
}

private struct StatPill: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: Spacing.xxSmall) {
            Text(label)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
            Text("\(count)")
                .font(Typography.caption1)
                .fontWeight(.bold)
                .foregroundColor(color)
                .padding(.horizontal, Spacing.xxSmall)
                .padding(.vertical, 1)
                .background(color.opacity(0.12))
                .cornerRadius(CornerRadius.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(count)")
    }
}
