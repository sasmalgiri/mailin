//
//  CommandPaletteView.swift
//  mailin
//
//  Spotlight-style command palette for quick access to all app features.
//

import SwiftUI

// MARK: - Palette Command

struct PaletteCommand: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let shortcut: String?
    let category: String
    let action: () -> Void
}

// MARK: - Command Palette View

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    /// External actions wired by the caller.
    var onCommand: ((String) -> Void)?

    // MARK: - Command Registry

    private var allCommands: [PaletteCommand] {
        [
            // Analysis
            PaletteCommand(name: "Ask AI", icon: "sparkles", shortcut: "\u{2318}K", category: "Analysis") {
                execute("askAI")
            },
            PaletteCommand(name: "Visual Analytics", icon: "chart.bar.fill", shortcut: "\u{21E7}\u{2318}G", category: "Analysis") {
                execute("analytics")
            },
            PaletteCommand(name: "Topic Clusters", icon: "rectangle.3.group.bubble", shortcut: nil, category: "Analysis") {
                execute("topicClusters")
            },
            PaletteCommand(name: "Duplicates", icon: "doc.on.doc", shortcut: nil, category: "Analysis") {
                execute("duplicates")
            },
            PaletteCommand(name: "Predictive Coding", icon: "brain.head.profile", shortcut: nil, category: "Analysis") {
                execute("predictiveCoding")
            },
            PaletteCommand(name: "Timeline", icon: "calendar.day.timeline.leading", shortcut: "\u{21E7}\u{2318}T", category: "Analysis") {
                execute("timeline")
            },
            PaletteCommand(name: "Relationship Graph", icon: "point.3.connected.trianglepath.dotted", shortcut: "\u{21E7}\u{2318}J", category: "Analysis") {
                execute("relationshipGraph")
            },
            PaletteCommand(name: "Smart Alerts", icon: "bell.badge.fill", shortcut: nil, category: "Analysis") {
                execute("smartAlerts")
            },
            PaletteCommand(name: "Anomaly Detection", icon: "exclamationmark.triangle", shortcut: nil, category: "Analysis") {
                execute("anomalyDetection")
            },
            PaletteCommand(name: "Auto-Tagger", icon: "tag.fill", shortcut: nil, category: "Analysis") {
                execute("autoTagger")
            },
            PaletteCommand(name: "Email Digest", icon: "text.document", shortcut: nil, category: "Analysis") {
                execute("emailDigest")
            },
            PaletteCommand(name: "Near-Duplicates", icon: "doc.on.doc.fill", shortcut: nil, category: "Analysis") {
                execute("nearDuplicates")
            },
            PaletteCommand(name: "Communication Patterns", icon: "waveform.path.ecg", shortcut: nil, category: "Analysis") {
                execute("commPatterns")
            },
            PaletteCommand(name: "Executive Dashboard", icon: "gauge.with.dots.needle.bottom.50percent", shortcut: nil, category: "Analysis") {
                execute("dashboard")
            },

            // Forensic
            PaletteCommand(name: "Toggle Forensic Mode", icon: "shield.checkered", shortcut: "\u{21E7}\u{2318}F", category: "Forensic") {
                execute("forensicMode")
            },
            PaletteCommand(name: "E-Discovery", icon: "magnifyingglass.circle", shortcut: nil, category: "Forensic") {
                execute("eDiscovery")
            },
            PaletteCommand(name: "Bates Numbering", icon: "number", shortcut: nil, category: "Forensic") {
                execute("batesNumbering")
            },
            PaletteCommand(name: "PII Redaction", icon: "eye.slash.fill", shortcut: nil, category: "Forensic") {
                execute("redaction")
            },
            PaletteCommand(name: "GDPR Report", icon: "doc.text.magnifyingglass", shortcut: nil, category: "Forensic") {
                execute("gdprReport")
            },
            PaletteCommand(name: "Chain of Custody", icon: "link", shortcut: nil, category: "Forensic") {
                execute("chainOfCustody")
            },
            PaletteCommand(name: "Custodian Manager", icon: "person.2.badge.gearshape", shortcut: nil, category: "Forensic") {
                execute("custodianManager")
            },
            PaletteCommand(name: "Review Batches", icon: "tray.2.fill", shortcut: nil, category: "Forensic") {
                execute("reviewBatches")
            },
            PaletteCommand(name: "Investigation Report", icon: "doc.richtext", shortcut: nil, category: "Forensic") {
                execute("investigationReport")
            },

            // Export
            PaletteCommand(name: "Export Filtered", icon: "square.and.arrow.up", shortcut: "\u{21E7}\u{2318}E", category: "Export") {
                execute("exportFiltered")
            },
            PaletteCommand(name: "Export vCard", icon: "person.crop.rectangle.fill", shortcut: nil, category: "Export") {
                execute("exportVCard")
            },
            PaletteCommand(name: "Export ICS", icon: "calendar", shortcut: nil, category: "Export") {
                execute("exportICS")
            },
            PaletteCommand(name: "Export MSG", icon: "envelope.fill", shortcut: nil, category: "Export") {
                execute("exportMSG")
            },
            PaletteCommand(name: "Export PST", icon: "archivebox.fill", shortcut: nil, category: "Export") {
                execute("exportPST")
            },
            PaletteCommand(name: "Export Relativity", icon: "tray.and.arrow.up.fill", shortcut: nil, category: "Export") {
                execute("exportRelativity")
            },

            // View
            PaletteCommand(name: "Toggle Sidebar", icon: "sidebar.leading", shortcut: "\u{2325}\u{2318}S", category: "View") {
                execute("toggleSidebar")
            },
            PaletteCommand(name: "Keyword Monitor", icon: "text.magnifyingglass", shortcut: nil, category: "View") {
                execute("keywordMonitor")
            },
            PaletteCommand(name: "Report Builder", icon: "doc.badge.gearshape", shortcut: nil, category: "View") {
                execute("reportBuilder")
            },
            PaletteCommand(name: "Workspaces", icon: "square.stack.3d.up", shortcut: nil, category: "View") {
                execute("workspaces")
            },
        ]
    }

    // MARK: - Filtered Commands

    private var filteredCommands: [PaletteCommand] {
        guard !searchText.isEmpty else { return allCommands }
        let query = searchText.lowercased()
        return allCommands.filter { command in
            command.name.lowercased().contains(query) ||
            command.category.lowercased().contains(query)
        }
    }

    private var visibleCommands: [PaletteCommand] {
        Array(filteredCommands.prefix(10))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.secondary)
                TextField("Search commands...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .focused($isSearchFocused)
                    .onSubmit {
                        executeSelected()
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Esc")
                        .font(Typography.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(AppColors.secondary)
                        .padding(.horizontal, Spacing.xSmall)
                        .padding(.vertical, Spacing.xxxSmall)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(CornerRadius.small)
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.medium)

            Divider()

            // Command list
            if visibleCommands.isEmpty {
                VStack {
                    Spacer()
                    Text("No matching commands")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleCommands.enumerated()), id: \.element.id) { index, command in
                                commandRow(command, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        selectedIndex = index
                                        executeSelected()
                                    }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        #if os(macOS)
        .frame(width: 500, height: 400)
        #endif
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < visibleCommands.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.return) {
            executeSelected()
            return .handled
        }
    }

    // MARK: - Command Row

    private func commandRow(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: command.icon)
                .font(Typography.body)
                .foregroundColor(isSelected ? .white : AppColors.primary)
                .frame(width: 24)

            Text(command.name)
                .font(Typography.body)
                .foregroundColor(isSelected ? .white : .primary)

            Text(command.category)
                .font(Typography.caption2)
                .fontWeight(.semibold)
                .foregroundColor(isSelected ? .white.opacity(0.8) : AppColors.secondary)
                .padding(.horizontal, Spacing.xSmall)
                .padding(.vertical, Spacing.xxxSmall)
                .background(
                    isSelected
                    ? Color.white.opacity(0.2)
                    : AppColors.backgroundSecondary
                )
                .cornerRadius(CornerRadius.small)

            Spacer()

            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(Typography.caption1)
                    .foregroundColor(isSelected ? .white.opacity(0.7) : AppColors.secondary)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(isSelected ? AppColors.primary : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(command.name), \(command.category)")
    }

    // MARK: - Actions

    private func executeSelected() {
        guard !visibleCommands.isEmpty, selectedIndex < visibleCommands.count else { return }
        visibleCommands[selectedIndex].action()
        dismiss()
    }

    private func execute(_ commandID: String) {
        onCommand?(commandID)
    }
}
