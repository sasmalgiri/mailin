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

@main
struct mailinApp: App {
    // MARK: - App State
    @StateObject private var appState = AppStateManager()
    @StateObject private var storeManager = StoreManager()
    @Environment(\.openWindow) private var openWindow
    
    // MARK: - Scene Configuration
    var body: some Scene {
        // Main window with proper sizing and controls
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(storeManager)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear {
                    configureAppearance()
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
            
            Button("Ask AI (Pro)...") {
                if storeManager.requirePremium() {
                    appState.showAIAssistant = true
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!appState.hasParsedEmails)
            
            Divider()
            
            Button("Detect Metadata") {
                appState.detectMetadata()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)
        }
    }
    
    // MARK: - Appearance Configuration
    private func configureAppearance() {
        #if os(macOS)
        // Modern macOS appearance
        if let window = NSApplication.shared.windows.first {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
        }
        #endif
    }
}
// MARK: - App State Manager
class AppStateManager: ObservableObject {
    @Published var triggerFileImport = false
    @Published var triggerExport = false
    @Published var showReplyStats = false
    @Published var showAIAssistant = false
    @Published var hasFilteredEmails = false
    @Published var hasParsedEmails = false
    @Published var sidebarVisible = true
    
    func toggleSidebar() {
        sidebarVisible.toggle()
    }
    
    func detectMetadata() {
        NotificationCenter.default.post(name: .detectMetadata, object: nil)
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let detectMetadata = Notification.Name("detectMetadata")
}

