//
//  mailinApp.swift
//  mailin
//
//  Created by administrator on 12/07/2025.
//
//  A professional email archive analyzer for Apple platforms.
//  Parses .mbox and .eml files with advanced filtering and AI insights.
//

import SwiftUI
import AppKit

@main
struct mailinApp: App {
    // MARK: - App State
    @StateObject private var appState = AppStateManager()
    @StateObject private var storeManager = StoreManager()
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @AppStorage("enableAIFeatures") private var enableAIFeatures = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Scene Configuration
    var body: some Scene {
        // Main window with proper sizing and controls
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(storeManager)
                .adaptiveLayout()
                .frame(minWidth: 700, idealWidth: 1100, minHeight: 500, idealHeight: 750)
                .sheet(isPresented: Binding(
                    get: { !personaManager.hasCompletedPersonaSelection },
                    set: { if !$0 { personaManager.completePersonaSelection() } }
                )) {
                    PersonaOnboardingView()
                }
                .onAppear {
                    configureAppearance()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await storeManager.checkEntitlements() }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            appCommands
        }
        
        #if os(macOS)
        // Settings window (Apple standard)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(storeManager)
        }
        
        // About window
        Window("About mailin", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 500)
        #endif
    }
    
    // MARK: - Menu Commands (Apple Standard)
    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About mailin") {
                #if os(macOS)
                openWindow(id: "about")
                #endif
            }
        }
        
        CommandGroup(after: .newItem) {
            Button("Open Email Archive...") {
                appState.triggerFileImport = true
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Divider()
            
            Button("Export Filtered Emails (Pro)...") {
                if storeManager.requirePremium() {
                    appState.triggerExport = true
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!appState.hasFilteredEmails)
        }
        
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                appState.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
        
        CommandMenu("Analysis") {
            Button("Reply Statistics...") {
                appState.showReplyStats = true
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)

            Button("Ask AI...") {
                appState.showAIAssistant = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!appState.hasParsedEmails || !enableAIFeatures)

            Button("Visual Analytics...") {
                appState.showAnalytics = true
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("Detect Metadata") {
                appState.detectMetadata()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)
        }

        CommandMenu("Forensic") {
            Toggle("Forensic Mode", isOn: $forensicManager.isEnabled)
                .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Button("Export Audit Log...") {
                appState.triggerAuditLogExport = true
            }
            .disabled(!forensicManager.isEnabled || forensicManager.auditLog.isEmpty)

            Button("Export Forensic CSV...") {
                appState.triggerForensicCSVExport = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Divider()

            Section("Evidence Tags") {
                Button("Tag: Relevant") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.relevant)
                }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Tag: Privileged") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.privileged)
                }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Tag: Irrelevant") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.irrelevant)
                }
                .keyboardShortcut("3", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Tag: Flagged") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.flagged)
                }
                .keyboardShortcut("4", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Tag: Suspicious") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.suspicious)
                }
                .keyboardShortcut("5", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Clear Tag") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.none)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)
            }
        }
    }
    
    private static var terminationObserverRegistered = false

    // MARK: - Appearance Configuration
    private func configureAppearance() {
        #if os(macOS)
        if let window = NSApp.mainWindow ?? NSApplication.shared.windows.first {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
        }
        if !Self.terminationObserverRegistered {
            Self.terminationObserverRegistered = true
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                EmailPersistence.flushPendingSaves()
            }
        }
        #endif
    }
}
// MARK: - App State Manager
@MainActor
class AppStateManager: ObservableObject {
    @Published var triggerFileImport = false
    @Published var triggerExport = false
    @Published var showReplyStats = false
    @Published var showAIAssistant = false
    @Published var showAnalytics = false
    @Published var showReplyStatsSheet = false
    @Published var hasFilteredEmails = false
    @Published var hasParsedEmails = false
    @Published var sidebarVisible = true
    @Published var triggerAuditLogExport = false
    @Published var triggerForensicCSVExport = false
    
    func toggleSidebar() {
        sidebarVisible.toggle()
    }
    
    func detectMetadata() {
        NotificationCenter.default.post(name: .detectMetadata, object: nil)
    }
}

// MARK: - Persona Onboarding

struct PersonaOnboardingView: View {
    @ObservedObject private var personaManager = PersonaManager.shared
    @State private var selected: PersonaManager.Persona = .general
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.small) {
                Image(systemName: "envelope.open.badge.clock")
                    .font(.system(size: 40))
                    .foregroundStyle(.linearGradient(
                        colors: [selected.accentColor, selected.accentColor.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))

                Text("Welcome to mailin")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text("How will you use mailin? This customizes your interface.")
                    .font(Typography.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Spacing.large)
            .padding(.bottom, Spacing.medium)

            ScrollView {
                VStack(spacing: Spacing.xSmall) {
                    ForEach(PersonaManager.Persona.allCases, id: \.rawValue) { persona in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { selected = persona }
                        } label: {
                            HStack(spacing: Spacing.small) {
                                Image(systemName: persona.icon)
                                    .font(.system(size: 22))
                                    .foregroundColor(persona.accentColor)
                                    .frame(width: 32, height: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(persona.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(persona.tagline)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                if selected == persona {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(persona.accentColor)
                                        .font(.system(size: 18))
                                }
                            }
                            .padding(Spacing.small)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.medium)
                                    .fill(selected == persona
                                          ? persona.accentColor.opacity(0.08)
                                          : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: CornerRadius.medium)
                                    .stroke(selected == persona
                                            ? persona.accentColor.opacity(0.4)
                                            : Color.gray.opacity(0.15), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.medium)
            }

            Divider()
                .padding(.top, Spacing.small)

            HStack {
                Text("You can change this anytime in Settings.")
                    .font(Typography.caption1)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Get Started") {
                    personaManager.selectedPersona = selected
                    personaManager.completePersonaSelection()
                    dismiss()
                }
                .buttonStyle(CompactPrimaryButtonStyle())
                .tint(selected.accentColor)
            }
            .padding(Spacing.medium)
        }
        .frame(width: 460, height: 480)
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let detectMetadata = Notification.Name("detectMetadata")
    static let dataClearedByUser = Notification.Name("dataClearedByUser")
    static let tagCurrentEmail = Notification.Name("tagCurrentEmail")
}

