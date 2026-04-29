//
//  SettingsView.swift
//  mailin
//
//  Apple-grade Settings interface following Human Interface Guidelines
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var storeManager: StoreManager
    @AppStorage("defaultSenderEmail") private var defaultSenderEmail = ""
    @AppStorage("autoDetectSender") private var autoDetectSender = true
    @AppStorage("showInlineImages") private var showInlineImages = true
    @AppStorage("maxAttachmentSize") private var maxAttachmentSize = 250.0
    @AppStorage("enableAIFeatures") private var enableAIFeatures = true
    @AppStorage("exportFormat") private var exportFormat = "EML"
    @State private var savedDataCleared = false
    
    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            
            parsingSettings
                .tabItem {
                    Label("Parsing", systemImage: "envelope.open")
                }
            
            displaySettings
                .tabItem {
                    Label("Display", systemImage: "eyeglasses")
                }
            
            advancedSettings
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 500, height: 450)
        .sheet(isPresented: $storeManager.showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
    }
    
    // MARK: - General Settings
    private var generalSettings: some View {
        Form {
            Section {
                TextField("Default Email Address", text: $defaultSenderEmail)
                    .help("Your primary email address for automatic filtering")
                
                Toggle("Auto-detect sender from emails", isOn: $autoDetectSender)
                    .help("Automatically identify your email from the most common sender")
            } header: {
                Text("Email Identity")
                    .font(.headline)
            }
            
            Section {
                Picker("Default Export Format", selection: $exportFormat) {
                    Text("EML Files").tag("EML")
                    Text("JSON").tag("JSON")
                    Text("Plain Text").tag("TXT")
                    Text("CSV").tag("CSV")
                }
            } header: {
                Text("Export")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Parsing Settings
    private var parsingSettings: some View {
        Form {
            Section {
                HStack {
                    Text("Maximum Attachment Size")
                    Spacer()
                    Text("\(Int(maxAttachmentSize)) MB")
                        .foregroundColor(.secondary)
                }
                
                Slider(value: $maxAttachmentSize, in: 10...500, step: 10) {
                    Text("Max Size")
                } minimumValueLabel: {
                    Text("10")
                } maximumValueLabel: {
                    Text("500")
                }
                
                Text("Attachments larger than this will be skipped during parsing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Attachments")
                    .font(.headline)
            }
            
            Section {
                Toggle("Enable inline images", isOn: $showInlineImages)
                    .help("Display embedded images in HTML emails")
                
                Toggle("Strict RFC compliance", isOn: .constant(false))
                    .disabled(true)
                    .help("Coming soon: Enable strict email parsing mode")
            } header: {
                Text("Content Processing")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Display Settings
    private var displaySettings: some View {
        Form {
            Section {
                Picker("Email List Density", selection: .constant("comfortable")) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                    Text("Spacious").tag("spacious")
                }
                
                Toggle("Show email previews", isOn: .constant(true))
                
                Toggle("Highlight quoted text", isOn: .constant(true))
            } header: {
                Text("Email List")
                    .font(.headline)
            }
            
            Section {
                ColorPicker("Accent Color", selection: .constant(Color.accentColor))
                    .disabled(true)
                    .help("System accent color is used")
                
                Picker("Theme", selection: .constant("system")) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .disabled(true)
                .help("Uses system appearance preference")
            } header: {
                Text("Appearance")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Advanced Settings
    private var advancedSettings: some View {
        Form {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    if storeManager.isPremium {
                        Label("Pro", systemImage: "crown.fill")
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)
                    } else {
                        Text("Free")
                            .foregroundColor(.secondary)
                    }
                }

                if !storeManager.isPremium {
                    Button("Upgrade to Pro") {
                        storeManager.showPaywall = true
                    }
                }

                Button("Restore Purchases") {
                    Task { await storeManager.restorePurchases() }
                }
            } header: {
                Text("Subscription")
                    .font(.headline)
            }

            Section {
                Toggle("Enable AI features", isOn: $enableAIFeatures)
                    .help("Show AI assistant and analysis features")
            } header: {
                Text("AI Assistant")
                    .font(.headline)
            }

            Section {
                Button("Clear saved email data") {
                    EmailPersistence.clear()
                    savedDataCleared = true
                }
                .disabled(savedDataCleared || !EmailPersistence.hasSavedData)

                if savedDataCleared {
                    Text("Saved data cleared. Restart the app to start fresh.")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Button("Clear all temporary files") {
                    clearTempFiles()
                }

                Button("Reset all settings") {
                    resetSettings()
                }
                .foregroundColor(.red)
            } header: {
                Text("Maintenance")
                    .font(.headline)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("About")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Actions
    private func clearTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("mailin") }
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }
    
    private func resetSettings() {
        defaultSenderEmail = ""
        autoDetectSender = true
        showInlineImages = true
        maxAttachmentSize = 250.0
        enableAIFeatures = true
        exportFormat = "EML"
    }
}

#Preview {
    SettingsView()
}
