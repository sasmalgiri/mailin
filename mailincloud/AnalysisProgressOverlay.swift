import SwiftUI

struct AnalysisProgressOverlay: View {
    @ObservedObject var coordinator: AnalysisCoordinator

    @State private var showAfterDelay = false

    var body: some View {
        Group {
            if coordinator.isActive && showAfterDelay {
                ZStack {
                    Color.black.opacity(0.08)

                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .stroke(coordinator.accentColor.opacity(0.15), lineWidth: 4)
                                .frame(width: 56, height: 56)

                            Circle()
                                .trim(from: 0, to: min(max(coordinator.progress, 0.02), 1.0))
                                .stroke(coordinator.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .frame(width: 56, height: 56)
                                .rotationEffect(.degrees(-90))

                            Text("\(Int(coordinator.progress * 100))%")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(coordinator.accentColor)
                                .contentTransition(.numericText())
                        }

                        Text(coordinator.stepLabel)
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        ProgressView(value: min(max(coordinator.progress, 0), 1))
                            .progressViewStyle(.linear)
                            .tint(coordinator.accentColor)
                            .frame(width: 200)

                        HStack(spacing: 12) {
                            Text("Step \(coordinator.currentStep)/\(coordinator.totalSteps)")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(.secondary)
                            Text(coordinator.elapsedFormatted)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        if coordinator.isStalled {
                            stallWarning
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else {
                            Button { coordinator.cancel() } label: {
                                Text("Cancel")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.08), radius: 10)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: coordinator.isActive && showAfterDelay)
        .animation(.easeInOut(duration: 0.25), value: coordinator.progress)
        .animation(.easeInOut(duration: 0.3), value: coordinator.isStalled)
        .task(id: coordinator.isActive) {
            if coordinator.isActive {
                showAfterDelay = false
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled {
                    withAnimation { showAfterDelay = true }
                }
            } else {
                withAnimation { showAfterDelay = false }
            }
        }
    }

    private var stallWarning: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))
                Text("No progress for \(coordinator.stallSeconds)s")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }

            HStack(spacing: 8) {
                Button("Keep Waiting") {
                    coordinator.advance(step: coordinator.currentStep, label: coordinator.stepLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Skip Step") { coordinator.skipStep() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Cancel All") { coordinator.cancel() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }
}
