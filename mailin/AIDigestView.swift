//
//  AIDigestView.swift
//  mailin
//
//  Displays an AI-generated email digest summary.
//

import SwiftUI

struct AIDigestView: View {
    let emails: [MBOXParser.RawEmail]
    var isPresented: Binding<Bool>?
    @State private var selectedPeriod: AIDigestGenerator.TimePeriod = .lastWeek
    @State private var sections: [AIDigestGenerator.DigestSection] = []
    @State private var isGenerating = false
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var showTutorial = false
    @Environment(\.dismiss) private var envDismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(AppColors.primary)
                Text("Email Digest")
                    .font(Typography.headline)
                Spacer()
                TutorialHelpButton(showTutorial: $showTutorial)
                if isPresented != nil {
                    Button("Done") { closeSheet() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(Spacing.medium)

            Divider()

            AIDisclaimerBanner()

            // Period picker + generate
            VStack(spacing: Spacing.small) {
                Picker("Time Period", selection: $selectedPeriod) {
                    ForEach(AIDigestGenerator.TimePeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if selectedPeriod == .custom {
                    HStack(spacing: Spacing.medium) {
                        DatePicker("From", selection: $customStart, displayedComponents: .date)
                            .labelsHidden()
                        Text("to")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        DatePicker("To", selection: $customEnd, displayedComponents: .date)
                            .labelsHidden()
                    }
                }

                Button(action: generate) {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "sparkles")
                        Text("Generate Digest")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isGenerating)
            }
            .padding(Spacing.medium)

            Divider()

            // Content
            if isGenerating {
                VStack {
                    Spacer()
                    ProgressView("Generating digest...")
                        .font(Typography.callout)
                    Spacer()
                }
            } else if sections.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: "No Digest Yet",
                        message: "Select a time period and tap Generate Digest to create a summary of your email archive."
                    )
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.large) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(Spacing.medium)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
        .featureTutorial(.aiDigest, key: "ai_digest_tutorial_seen", isPresented: $showTutorial)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    // MARK: - Section View

    private func sectionView(_ section: AIDigestGenerator.DigestSection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            // Section header
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: section.icon)
                    .font(Typography.title3)
                    .foregroundColor(AppColors.primary)
                Text(section.title)
                    .font(Typography.title3)
            }

            Divider()

            ForEach(section.items) { item in
                digestItemView(item)
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    private func digestItemView(_ item: AIDigestGenerator.DigestItem) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            // Priority indicator
            Circle()
                .fill(priorityColor(item.priority))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                HStack {
                    Text(item.headline)
                        .font(Typography.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    if item.priority == .high {
                        priorityBadge(item.priority)
                    }
                    if !item.emailIDs.isEmpty {
                        Text("\(item.emailIDs.count)")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                            .padding(.horizontal, Spacing.xSmall)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.small)
                                    .fill(AppColors.backgroundSecondary)
                            )
                    }
                }

                Text(item.detail)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, Spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.priority.label) priority: \(item.headline). \(item.detail)")
    }

    private func priorityBadge(_ priority: AIDigestGenerator.DigestItem.Priority) -> some View {
        Text(priority.label.uppercased())
            .font(Typography.caption2)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.xSmall)
            .padding(.vertical, 2)
            .background(priorityColor(priority))
            .cornerRadius(CornerRadius.small)
    }

    // MARK: - Helpers

    private func priorityColor(_ priority: AIDigestGenerator.DigestItem.Priority) -> Color {
        switch priority {
        case .high: return AppColors.error
        case .medium: return AppColors.warning
        case .low: return AppColors.info
        }
    }

    private func generate() {
        isGenerating = true
        let period = selectedPeriod
        let start = customStart
        let end = customEnd
        let emailList = emails

        Task.detached {
            let results = await AIDigestGenerator.generateDigest(
                emails: emailList,
                period: period,
                customStart: period == .custom ? start : nil,
                customEnd: period == .custom ? end : nil
            )
            await MainActor.run {
                sections = results
                isGenerating = false
            }
        }
    }
}
