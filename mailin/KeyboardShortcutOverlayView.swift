//
//  KeyboardShortcutOverlayView.swift
//  mailin
//
//  Visual reference overlay of all keyboard shortcuts.
//

import SwiftUI

struct KeyboardShortcutOverlayView: View {
    @Environment(\.dismiss) private var dismiss

    // MARK: - Models

    struct ShortcutGroup: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let shortcuts: [ShortcutItem]
    }

    struct ShortcutItem: Identifiable {
        let id = UUID()
        let keys: String
        let description: String
    }

    // MARK: - Shortcut Data

    private let groups: [ShortcutGroup] = [
        ShortcutGroup(
            title: "File",
            icon: "doc",
            shortcuts: [
                ShortcutItem(keys: "\u{2318}N", description: "New Import"),
                ShortcutItem(keys: "\u{2318}O", description: "Open Archive"),
                ShortcutItem(keys: "\u{21E7}\u{2318}E", description: "Export"),
                ShortcutItem(keys: "\u{2318}P", description: "Print"),
            ]
        ),
        ShortcutGroup(
            title: "Edit",
            icon: "pencil",
            shortcuts: [
                ShortcutItem(keys: "\u{2318}F", description: "Find"),
                ShortcutItem(keys: "\u{2318}A", description: "Select All"),
            ]
        ),
        ShortcutGroup(
            title: "Analysis",
            icon: "chart.bar.fill",
            shortcuts: [
                ShortcutItem(keys: "\u{2318}K", description: "Ask AI"),
                ShortcutItem(keys: "\u{21E7}\u{2318}G", description: "Analytics"),
                ShortcutItem(keys: "\u{21E7}\u{2318}R", description: "Reply Stats"),
                ShortcutItem(keys: "\u{21E7}\u{2318}T", description: "Timeline"),
                ShortcutItem(keys: "\u{21E7}\u{2318}J", description: "Relationship Graph"),
                ShortcutItem(keys: "\u{21E7}\u{2318}U", description: "Automation Rules"),
            ]
        ),
        ShortcutGroup(
            title: "Forensic",
            icon: "shield.checkered",
            shortcuts: [
                ShortcutItem(keys: "\u{21E7}\u{2318}F", description: "Forensic Mode"),
                ShortcutItem(keys: "\u{2318}1\u{2013}5", description: "Evidence Tags"),
                ShortcutItem(keys: "\u{2318}0", description: "Clear Tag"),
            ]
        ),
        ShortcutGroup(
            title: "View",
            icon: "eye",
            shortcuts: [
                ShortcutItem(keys: "\u{2325}\u{2318}S", description: "Toggle Sidebar"),
                ShortcutItem(keys: "\u{21E7}\u{2318}P", description: "Command Palette"),
            ]
        ),
        ShortcutGroup(
            title: "Navigation",
            icon: "arrow.up.arrow.down",
            shortcuts: [
                ShortcutItem(keys: "\u{2191}\u{2193}", description: "Email list"),
                ShortcutItem(keys: "\u{2190}\u{2192}", description: "Panels"),
                ShortcutItem(keys: "Space", description: "Preview"),
            ]
        ),
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            shortcutGrid
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 620, maxWidth: 800, minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "keyboard")
                .foregroundColor(AppColors.primary)
            Text("Keyboard Shortcuts")
                .font(Typography.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.medium)
    }

    // MARK: - Shortcut Grid

    private var shortcutGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Spacing.medium),
                    GridItem(.flexible(), spacing: Spacing.medium),
                ],
                spacing: Spacing.medium
            ) {
                ForEach(groups) { group in
                    shortcutGroupView(group)
                }
            }
            .padding(Spacing.medium)
        }
    }

    // MARK: - Group View

    private func shortcutGroupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            // Group header
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: group.icon)
                    .foregroundColor(AppColors.primary)
                    .font(Typography.subheadline)
                Text(group.title)
                    .font(Typography.subheadline)
                    .fontWeight(.semibold)
            }
            .padding(.bottom, Spacing.xxxSmall)

            // Shortcut rows
            VStack(spacing: Spacing.xSmall) {
                ForEach(group.shortcuts) { item in
                    shortcutRow(item)
                }
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
        .shadow(color: .black.opacity(0.03), radius: Shadows.small.radius, x: 0, y: Shadows.small.y)
    }

    // MARK: - Shortcut Row

    private func shortcutRow(_ item: ShortcutItem) -> some View {
        HStack {
            keyBadge(item.keys)
            Spacer()
            Text(item.description)
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.keys): \(item.description)")
    }

    // MARK: - Key Badge

    private func keyBadge(_ keys: String) -> some View {
        // Split key string into individual key segments for badge display
        let segments = splitKeys(keys)
        return HStack(spacing: Spacing.xxxSmall) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Text(segment)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, Spacing.xxxSmall)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.small)
                            .fill(AppColors.backgroundSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: CornerRadius.small)
                                    .stroke(AppColors.separator, lineWidth: 0.5)
                            )
                    )
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            }
        }
    }

    /// Splits a key combination into segments for individual badge rendering.
    /// e.g. "\u{21E7}\u{2318}G" -> ["\u{21E7}", "\u{2318}", "G"]
    /// e.g. "\u{2318}1\u{2013}5" -> ["\u{2318}", "1\u{2013}5"]
    /// e.g. "Space" -> ["Space"]
    private func splitKeys(_ keys: String) -> [String] {
        // Known modifier/symbol characters to split on
        let modifiers: Set<Character> = [
            "\u{2318}", // Command
            "\u{21E7}", // Shift
            "\u{2325}", // Option
            "\u{2303}", // Control
        ]

        var segments: [String] = []
        var current = ""

        for char in keys {
            if modifiers.contains(char) {
                if !current.isEmpty {
                    segments.append(current)
                    current = ""
                }
                segments.append(String(char))
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }

        return segments
    }
}
