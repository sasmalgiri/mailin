//
//  BiometricLockManager.swift
//  mailin
//
//  Biometric authentication (Touch ID / Face ID) for protecting the app.
//

import SwiftUI
import LocalAuthentication

@MainActor
class BiometricLockManager: ObservableObject {
    static let shared = BiometricLockManager()

    @Published var isLocked = false
    @Published var isAuthenticating = false
    @Published var authError: String?
    @Published var biometricType: BiometricType = .none

    @AppStorage("biometricLockEnabled") var isEnabled = false
    @AppStorage("lockOnMinimize") var lockOnMinimize = true
    @AppStorage("lockTimeoutMinutes") var lockTimeoutMinutes = 5

    private var autoLockTask: Task<Void, Never>?
    private var backgroundDate: Date?

    // MARK: - Biometric Type

    enum BiometricType {
        case none, touchID, faceID, opticID

        var displayName: String {
            switch self {
            case .none: return "None"
            case .touchID: return "Touch ID"
            case .faceID: return "Face ID"
            case .opticID: return "Optic ID"
            }
        }

        var icon: String {
            switch self {
            case .none: return "lock.slash"
            case .touchID: return "touchid"
            case .faceID: return "faceid"
            case .opticID: return "opticid"
            }
        }
    }

    // MARK: - Init

    private init() {
        checkBiometricAvailability()
        if isEnabled {
            isLocked = true
        }
    }

    // MARK: - Availability

    func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch context.biometryType {
            case .touchID:
                biometricType = .touchID
            case .faceID:
                biometricType = .faceID
            case .opticID:
                biometricType = .opticID
            default:
                biometricType = .none
            }
        } else {
            biometricType = .none
        }
    }

    // MARK: - Authentication

    func authenticate() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        authError = nil

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        let policy: LAPolicy
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            policy = .deviceOwnerAuthentication
        } else {
            isAuthenticating = false
            isLocked = false
            isEnabled = false
            authError = biometricUnavailableMessage(for: error) + " Biometric lock has been disabled to prevent lockout."
            return true
        }

        do {
            let success = try await context.evaluatePolicy(
                policy,
                localizedReason: "Unlock mailin to access email archives"
            )
            isAuthenticating = false
            if success {
                isLocked = false
                authError = nil
                return true
            } else {
                authError = "Authentication was not successful."
                return false
            }
        } catch let laError as LAError {
            isAuthenticating = false
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                authError = nil
            case .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
                let fallbackContext = LAContext()
                if fallbackContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                    do {
                        let success = try await fallbackContext.evaluatePolicy(
                            .deviceOwnerAuthentication,
                            localizedReason: "Unlock mailin with your device passcode"
                        )
                        if success {
                            isLocked = false
                            return true
                        }
                    } catch {}
                }
                authError = "Authentication unavailable. Please try again later."
            case .authenticationFailed:
                authError = "Authentication failed. Please try again."
            default:
                authError = laError.localizedDescription
            }
            return false
        } catch {
            isAuthenticating = false
            authError = error.localizedDescription
            return false
        }
    }

    // MARK: - Lock

    func lock() {
        guard isEnabled else {
            isLocked = false
            return
        }
        isLocked = true
        authError = nil
    }

    func ensureUnlockedIfDisabled() {
        if !isEnabled && isLocked {
            isLocked = false
            authError = nil
        }
    }

    // MARK: - Auto-Lock Timer

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        ensureUnlockedIfDisabled()
        guard isEnabled else { return }

        switch newPhase {
        case .background, .inactive:
            if lockOnMinimize && newPhase == .background {
                lock()
            } else {
                backgroundDate = Date()
                startAutoLockTimer()
            }
        case .active:
            autoLockTask?.cancel()
            autoLockTask = nil
            if let bg = backgroundDate {
                let elapsed = Date().timeIntervalSince(bg)
                if elapsed >= TimeInterval(lockTimeoutMinutes * 60) {
                    lock()
                }
                backgroundDate = nil
            }
        @unknown default:
            break
        }
    }

    func startAutoLockTimer() {
        autoLockTask?.cancel()
        let timeout = TimeInterval(lockTimeoutMinutes * 60)
        autoLockTask = Task { [weak self] in
            let safeNanos = UInt64(min(timeout, 86400) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: safeNanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.lock()
            }
        }
    }

    // MARK: - Helpers

    private func biometricUnavailableMessage(for error: NSError?) -> String {
        guard let laError = error as? LAError else {
            return "Biometric authentication is not available."
        }
        switch laError.code {
        case .biometryNotEnrolled:
            return "No biometric authentication is enrolled. Please set it up in System Settings."
        case .biometryLockout:
            return "Biometric authentication is temporarily locked out."
        case .biometryNotAvailable:
            return "Biometric authentication is not available on this device."
        default:
            return laError.localizedDescription
        }
    }
}

// MARK: - Biometric Lock View

struct BiometricLockView: View {
    @ObservedObject var manager: BiometricLockManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Glass-style background
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: Spacing.large) {
                // App icon
                PlatformApp.appIconImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)

                // Lock title
                VStack(spacing: Spacing.xSmall) {
                    Text("mailin is Locked")
                        .font(Typography.title2)

                    Text("Authenticate to access your email archives")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                        .multilineTextAlignment(.center)
                }

                // Biometric icon
                Image(systemName: manager.biometricType.icon)
                    .font(.system(size: 48))
                    .foregroundColor(AppColors.primary)
                    .padding(.vertical, Spacing.small)

                // Error message
                if let error = manager.authError {
                    Text(error)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.large)
                        .transition(.opacity)
                }

                // Unlock button
                Button {
                    Task {
                        _ = await manager.authenticate()
                    }
                } label: {
                    HStack(spacing: Spacing.xSmall) {
                        if manager.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: manager.biometricType.icon)
                        }
                        Text("Unlock with \(manager.biometricType.displayName)")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(manager.isAuthenticating)

                // Fallback for no biometric
                if manager.biometricType == .none {
                    Text("No biometric authentication available on this device.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.large)
                }
            }
            .padding(Spacing.xxLarge)
            .adaptiveCard(cornerRadius: CornerRadius.xLarge)
            .frame(maxWidth: 380)
        }
        .onAppear {
            if manager.biometricType != .none {
                Task {
                    _ = await manager.authenticate()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App is locked. Authenticate to continue.")
    }
}
