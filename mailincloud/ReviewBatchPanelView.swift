import SwiftUI

struct ReviewBatchPanelView: View {
    let emails: [MBOXParser.RawEmail]
    @ObservedObject var manager: ReviewBatchManager
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss
    @State private var batchSize = 50
    @State private var hasCreatedBatches = false
    @State private var showTutorial = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.batches.isEmpty {
                setupView
            } else {
                batchReviewView
            }
        }
        .featureTutorial(.reviewBatches, key: "review_batches_tutorial_seen", isPresented: $showTutorial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label("Review Batches", systemImage: "rectangle.stack.badge.play")
                    .font(Typography.title2)
                Text("Systematically review emails in manageable batches.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            if !manager.batches.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Overall: \(Int(manager.totalProgress * 100))%")
                        .font(Typography.caption1)
                        .fontWeight(.semibold)
                    ProgressView(value: manager.totalProgress)
                        .frame(width: 100)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Overall review progress")
                .accessibilityValue("\(Int(manager.totalProgress * 100)) percent complete")
            }
            TutorialHelpButton(showTutorial: $showTutorial)
            if isPresented != nil {
                Button { closeSheet() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close review batches")
            }
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private var setupView: some View {
        VStack(spacing: Spacing.large) {
            Spacer()
            Image(systemName: "rectangle.stack")
                .font(.largeTitle)
                .foregroundColor(AppColors.primary.opacity(0.4))

            Text("Create Review Batches")
                .font(Typography.title2)

            Text("Split \(emails.count) emails into batches for systematic review.")
                .font(Typography.body)
                .foregroundColor(AppColors.secondary)

            HStack {
                Text("Batch Size:")
                    .font(Typography.callout)
                Stepper("\(batchSize)", value: $batchSize, in: 10...500, step: 10)
                    .frame(width: 140)
            }

            Button("Create \(max(1, emails.count / max(1, batchSize))) Batches") {
                manager.createBatches(from: emails.map(\.id), batchSize: batchSize)
                hasCreatedBatches = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Create \(max(1, emails.count / max(1, batchSize))) review batches")
            .accessibilityHint("Splits \(emails.count) emails into batches of \(batchSize)")

            Spacer()
        }
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity)
    }

    private var batchReviewView: some View {
        VStack(spacing: 0) {
            batchNavigator
            Divider()
            if let batch = manager.currentBatch {
                batchContent(batch)
            }
        }
    }

    private var batchNavigator: some View {
        HStack(spacing: Spacing.small) {
            Button {
                manager.previousBatch()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(manager.currentBatchIndex == 0)
            .accessibilityLabel("Previous batch")

            ForEach(Array(manager.batches.enumerated()), id: \.element.id) { idx, batch in
                Button {
                    manager.goToBatch(idx)
                } label: {
                    VStack(spacing: 2) {
                        Text(batch.name)
                            .font(Typography.caption2)
                            .fontWeight(idx == manager.currentBatchIndex ? .bold : .regular)
                        ProgressView(value: batch.progress)
                            .frame(width: 40)
                            .tint(batch.progress >= 1.0 ? .green : .blue)
                    }
                    .padding(.horizontal, Spacing.xxSmall)
                    .padding(.vertical, Spacing.xxxSmall)
                    .background(idx == manager.currentBatchIndex ? AppColors.primary.opacity(0.1) : Color.clear)
                    .cornerRadius(CornerRadius.small)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(batch.name), \(Int(batch.progress * 100)) percent reviewed")
                .accessibilityAddTraits(idx == manager.currentBatchIndex ? .isSelected : [])
            }

            Button {
                manager.nextBatch()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(manager.currentBatchIndex >= manager.batches.count - 1)
            .accessibilityLabel("Next batch")

            Spacer()

            Button("Reset") {
                manager.reset()
            }
            .buttonStyle(CompactSecondaryButtonStyle())
            .accessibilityLabel("Reset all batches")
            .accessibilityHint("Removes all batches and review progress")
        }
        .padding(Spacing.small)
        .background(AppColors.backgroundSecondary)
    }

    private func batchContent(_ batch: ReviewBatchManager.ReviewBatch) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack {
                Text(batch.name)
                    .font(Typography.headline)
                Spacer()
                Text("\(batch.reviewedIDs.count)/\(batch.emailIDs.count) reviewed")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                Text("\(batch.pendingCount) pending")
                    .font(Typography.caption1)
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, Spacing.small)
            .padding(.top, Spacing.small)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(batch.name): \(batch.reviewedIDs.count) of \(batch.emailIDs.count) reviewed, \(batch.pendingCount) pending")

            List {
                ForEach(batch.emailIDs, id: \.self) { emailID in
                    if let email = emails.first(where: { $0.id == emailID }) {
                        HStack {
                            if batch.reviewedIDs.contains(emailID) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .accessibilityLabel("Reviewed")
                            } else if batch.skippedIDs.contains(emailID) {
                                Image(systemName: "forward.circle.fill")
                                    .foregroundColor(.orange)
                                    .accessibilityLabel("Skipped")
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(AppColors.secondary)
                                    .accessibilityLabel("Pending review")
                            }

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

                            Button {
                                manager.markReviewed(emailID)
                            } label: {
                                Text("Reviewed")
                                    .font(Typography.caption2)
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            .controlSize(.small)
                            .accessibilityLabel("Mark as reviewed")

                            Button {
                                manager.markSkipped(emailID)
                            } label: {
                                Text("Skip")
                                    .font(Typography.caption2)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Skip this email")
                        }
                    }
                }
            }
        }
    }
}
