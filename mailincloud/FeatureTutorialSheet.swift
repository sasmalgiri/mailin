//
//  FeatureTutorialSheet.swift
//  mailin
//
//  Reusable tutorial/help sheet for all features.
//  Each feature defines a FeatureTutorial with steps and tips.
//

import SwiftUI

// MARK: - Data Models

struct TutorialStep: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let color: Color
    let what: String
    let how: String
    let tip: String
}

struct TutorialTip: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}

struct FeatureTutorial {
    let title: String
    let icon: String
    let overview: String
    let quickStart: String
    let steps: [TutorialStep]
    let tips: [TutorialTip]
}

// MARK: - Reusable Tutorial Sheet

struct FeatureTutorialSheet: View {
    let tutorial: FeatureTutorial
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            tutorialHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    overviewCard
                    quickStartCard
                    stepsCard
                    if !tutorial.tips.isEmpty { tipsCard }
                }
                .padding(Spacing.medium)
            }

            Divider()
            tutorialFooter
        }
        .background(AppColors.backgroundPrimary)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 740,
               minHeight: 480, idealHeight: 620, maxHeight: 800)
        #endif
    }

    private var tutorialHeader: some View {
        HStack {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 20))
                .foregroundColor(AppColors.primary)
            Text(tutorial.title)
                .font(Typography.title2)
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
        }
        .padding(Spacing.medium)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Label("Overview", systemImage: "info.circle.fill")
                .font(Typography.headline)
                .foregroundColor(AppColors.primary)
            Text(tutorial.overview)
                .font(Typography.body)
                .foregroundColor(AppColors.secondary)
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private var quickStartCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Label("Quick Start", systemImage: "bolt.fill")
                .font(Typography.headline)
                .foregroundColor(.orange)
            Text(tutorial.quickStart)
                .font(Typography.body)
                .foregroundColor(AppColors.secondary)
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Label("How It Works", systemImage: "list.number")
                .font(Typography.headline)
                .foregroundColor(AppColors.primary)

            ForEach(Array(tutorial.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(number: "\(index + 1)", step: step)
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private func stepRow(number: String, step: TutorialStep) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                ZStack {
                    Circle()
                        .fill(step.color.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: step.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(step.color)
                }
                Text("Step \(number): \(step.title)")
                    .font(Typography.callout)
                    .fontWeight(.semibold)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(step.what)
                    .font(Typography.body)
                    .fontWeight(.medium)
                Text(step.how)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "lightbulb.min")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                    Text(step.tip)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .italic()
                }
                .padding(.top, 2)
            }
            .padding(.leading, 36)
        }
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Label("Tips", systemImage: "lightbulb.fill")
                .font(Typography.headline)
                .foregroundColor(.yellow)

            ForEach(tutorial.tips) { tip in
                HStack(alignment: .top, spacing: Spacing.xSmall) {
                    Image(systemName: tip.icon)
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.primary)
                        .frame(width: 16)
                    Text(tip.text)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private var tutorialFooter: some View {
        HStack {
            Spacer()
            Button { isPresented = false } label: {
                Text("Got It — Start Working")
                    .fontWeight(.semibold)
            }
            .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .padding(Spacing.medium)
    }
}

// MARK: - Help Button

struct TutorialHelpButton: View {
    @Binding var showTutorial: Bool

    var body: some View {
        Button { showTutorial = true } label: {
            Image(systemName: "questionmark.circle")
                .imageScale(.large)
                .foregroundColor(AppColors.primary)
        }
        .buttonStyle(.plain)
        .help("How to use this feature")
        .accessibilityLabel("Show tutorial")
    }
}

// MARK: - View Modifier

struct FeatureTutorialModifier: ViewModifier {
    let tutorial: FeatureTutorial
    let defaultsKey: String
    @Binding var showTutorial: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showTutorial) {
                FeatureTutorialSheet(tutorial: tutorial, isPresented: $showTutorial)
            }
            .onAppear {
                if !UserDefaults.standard.bool(forKey: defaultsKey) {
                    showTutorial = true
                    UserDefaults.standard.set(true, forKey: defaultsKey)
                }
            }
    }
}

extension View {
    func featureTutorial(_ tutorial: FeatureTutorial, key: String, isPresented: Binding<Bool>) -> some View {
        modifier(FeatureTutorialModifier(tutorial: tutorial, defaultsKey: key, showTutorial: isPresented))
    }
}
