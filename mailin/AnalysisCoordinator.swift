import Foundation
import SwiftUI

@MainActor
final class AnalysisCoordinator: ObservableObject {

    // MARK: - Module Toggle

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "analysisCoordinatorEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "analysisCoordinatorEnabled") }
    }

    // MARK: - Published State

    @Published var progress: Double = 0
    @Published var stepLabel: String = ""
    @Published var isActive = false
    @Published var isStalled = false
    @Published var stallSeconds: Int = 0
    @Published var isCancelled = false
    @Published var totalSteps: Int = 0
    @Published var currentStep: Int = 0
    @Published var elapsedSeconds: Int = 0

    var accentColor: Color = .blue

    // MARK: - Configuration

    static var stallThreshold: Int = 30

    // MARK: - Private

    private var lastProgressUpdate = Date()
    private var startTime = Date()
    private var stallMonitor: Task<Void, Never>?
    private var elapsedMonitor: Task<Void, Never>?
    private var skipFlag = false

    // MARK: - Lifecycle

    func begin(steps: Int, color: Color = .blue) {
        progress = 0
        stepLabel = "Preparing..."
        isActive = true
        isStalled = false
        stallSeconds = 0
        isCancelled = false
        skipFlag = false
        totalSteps = steps
        currentStep = 0
        elapsedSeconds = 0
        accentColor = color
        lastProgressUpdate = Date()
        startTime = Date()
        startMonitors()
    }

    func advance(step: Int, label: String) {
        guard !isCancelled else { return }
        currentStep = step
        progress = Double(step) / Double(totalSteps)
        stepLabel = label
        lastProgressUpdate = Date()
        isStalled = false
        stallSeconds = 0
        skipFlag = false
    }

    func finish() {
        progress = 1.0
        isActive = false
        isStalled = false
        stallMonitor?.cancel()
        elapsedMonitor?.cancel()
    }

    func cancel() {
        isCancelled = true
        isActive = false
        isStalled = false
        stallMonitor?.cancel()
        elapsedMonitor?.cancel()
    }

    func skipStep() {
        skipFlag = true
        lastProgressUpdate = Date()
        isStalled = false
        stallSeconds = 0
    }

    // MARK: - Query

    var shouldContinue: Bool { !isCancelled }
    var shouldSkip: Bool { skipFlag }

    var elapsedFormatted: String {
        let mins = elapsedSeconds / 60
        let secs = elapsedSeconds % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }

    // MARK: - Off-MainActor Execution

    func runDetached<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T? {
        guard shouldContinue else { return nil }
        if shouldSkip { skipFlag = false; return nil }
        return await Task.detached(priority: .userInitiated) { work() }.value
    }

    // MARK: - Monitors

    private func startMonitors() {
        stallMonitor?.cancel()
        elapsedMonitor?.cancel()

        stallMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isActive else { break }
                let since = Int(Date().timeIntervalSince(self.lastProgressUpdate))
                self.stallSeconds = since
                if since >= Self.stallThreshold && !self.isStalled {
                    self.isStalled = true
                }
            }
        }

        elapsedMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isActive else { break }
                self.elapsedSeconds = Int(Date().timeIntervalSince(self.startTime))
            }
        }
    }
}
