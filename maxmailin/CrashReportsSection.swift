//
//  CrashReportsSection.swift
//  maxmailin
//
//  CRASH-02 (owner 2026-11-23: "no need to put crash report on app window
//  instead put it in some folder and put the path in system ui"). Settings ▸
//  Crash reports names the folder where mailin keeps its crash and diagnostics
//  reports on this device, how many there are, and lets the person open the
//  folder (Mac) or share the reports (iPhone, iPad — the folder is not visible
//  in Files there). Nothing is sent anywhere.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct CrashReportsSection: View {
    @State private var files: [URL] = []
    @State private var note: String?

    private var folder: URL { DiagnosticsCenter.directory }

    var body: some View {
        Section {
            LabeledContent(String(localized: "Reports"), value: "\(files.count)")
                .accessibilityIdentifier("settings.crashReports.count")
            VStack(alignment: .leading, spacing: 2) {
                Text("Folder").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: folder.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.crashReports.path")
            }
            HStack {
                #if os(macOS)
                Button(String(localized: "Show in Finder")) {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                .accessibilityIdentifier("settings.crashReports.show")
                #else
                if !files.isEmpty {
                    ShareLink(items: files) { Text("Share reports") }
                        .accessibilityIdentifier("settings.crashReports.share")
                }
                #endif
                Button(String(localized: "Copy path")) {
                    PlatformClipboard.copyString(folder.path)
                    note = String(localized: "Path copied.")
                }
                .accessibilityIdentifier("settings.crashReports.copyPath")
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Crash reports").font(.headline)
        } footer: {
            Text("If mailin stops unexpectedly, the next launch writes a report to this folder and switches off the engine that was running. Reports stay on this device; nothing is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { files = DiagnosticsCenter.reportFiles() }
    }
}
