//
//  WorkspaceManagerView.swift
//  mailin
//
//  SwiftUI view for managing multi-archive workspaces.
//

import SwiftUI

struct WorkspaceManagerView: View {
    @ObservedObject private var manager = WorkspaceManager.shared
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss
    @State private var showNewWorkspaceSheet = false
    @State private var workspaceToDelete: WorkspaceManager.Workspace?
    @State private var showDeleteConfirmation = false
    @State private var showSwitchConfirmation = false
    @State private var pendingSwitchID: UUID?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
        .sheet(isPresented: $showNewWorkspaceSheet) {
            NewWorkspaceSheet()
        }
        .adaptiveDestructiveConfirmation(
            "Delete Workspace",
            isPresented: $showDeleteConfirmation,
            message: "This will permanently delete the workspace \"\(workspaceToDelete?.name ?? "")\". This action cannot be undone.",
            actionTitle: "Delete"
        ) {
            if let ws = workspaceToDelete {
                manager.deleteWorkspace(id: ws.id)
                workspaceToDelete = nil
            }
        }
        .confirmationDialog("Switch Workspace", isPresented: $showSwitchConfirmation) {
            Button("Switch") {
                if let id = pendingSwitchID {
                    manager.switchToWorkspace(id: id)
                    pendingSwitchID = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingSwitchID = nil }
        } message: {
            Text("Switch to this workspace? Your current context will be saved.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "square.stack.3d.up")
                .foregroundColor(AppColors.primary)
            Text("Workspaces")
                .font(Typography.headline)
            Spacer()
            Button {
                showNewWorkspaceSheet = true
            } label: {
                Label("New Workspace", systemImage: "plus")
            }
            .buttonStyle(CompactPrimaryButtonStyle())
            if isPresented != nil {
                Button("Done") { closeSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if manager.workspaces.isEmpty {
            VStack {
                Spacer()
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No Workspaces Yet",
                    message: "Create one to organize your investigations.",
                    actionTitle: "New Workspace"
                ) {
                    showNewWorkspaceSheet = true
                }
                Spacer()
            }
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: Spacing.medium)],
                    spacing: Spacing.medium
                ) {
                    ForEach(manager.sortedWorkspaces) { workspace in
                        workspaceCard(workspace)
                            .adaptiveScrollTransition()
                    }
                }
                .padding(Spacing.medium)
            }
        }
    }

    // MARK: - Workspace Card

    private func workspaceCard(_ workspace: WorkspaceManager.Workspace) -> some View {
        let isActive = workspace.id == manager.activeWorkspaceID
        let color = manager.colorForName(workspace.color)

        return Button {
            pendingSwitchID = workspace.id
            showSwitchConfirmation = true
        } label: {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundColor(color)

                    VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                        HStack(spacing: Spacing.xxSmall) {
                            Text(workspace.name)
                                .font(Typography.headline)
                                .lineLimit(1)
                            if workspace.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.warning)
                            }
                        }

                        if !workspace.description.isEmpty {
                            Text(workspace.description)
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    if isActive {
                        Text("Active")
                            .font(Typography.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, Spacing.xSmall)
                            .padding(.vertical, Spacing.xxxSmall)
                            .background(color)
                            .cornerRadius(CornerRadius.small)
                    }
                }

                Divider()

                HStack(spacing: Spacing.medium) {
                    Label("\(workspace.emailCount)", systemImage: "envelope")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)

                    Label("\(workspace.sourceFiles.count) files", systemImage: "doc")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)

                    Spacer()

                    Text(relativeDate(workspace.lastAccessedAt))
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }
            .padding(Spacing.medium)
            .background(AppColors.backgroundTertiary)
            .cornerRadius(CornerRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .stroke(isActive ? color : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.05), radius: Shadows.small.radius, x: 0, y: Shadows.small.y)
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .contextMenu {
            Button {
                var updated = workspace
                updated.isPinned.toggle()
                manager.updateWorkspace(updated)
            } label: {
                Label(workspace.isPinned ? "Unpin" : "Pin", systemImage: workspace.isPinned ? "pin.slash" : "pin")
            }
            Divider()
            Button(role: .destructive) {
                workspaceToDelete = workspace
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.name), \(workspace.emailCount) emails, \(isActive ? "active" : "inactive")")
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - New Workspace Sheet

struct NewWorkspaceSheet: View {
    @ObservedObject private var manager = WorkspaceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var selectedColor = "blue"

    var body: some View {
        VStack(spacing: Spacing.large) {
            HStack {
                Text("New Workspace")
                    .font(Typography.title3)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, Spacing.xSmall)

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Text("Name")
                    .font(Typography.subheadline)
                    .fontWeight(.semibold)
                TextField("Investigation name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Text("Description")
                    .font(Typography.subheadline)
                    .fontWeight(.semibold)
                TextField("Optional description", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Text("Color")
                    .font(Typography.subheadline)
                    .fontWeight(.semibold)
                HStack(spacing: Spacing.small) {
                    ForEach(WorkspaceManager.Workspace.availableColors, id: \.self) { colorName in
                        let color = manager.colorForName(colorName)
                        Button {
                            selectedColor = colorName
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColor == colorName ? 2 : 0)
                                        .padding(-2)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(colorName)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Create Workspace") {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    manager.createWorkspace(name: name, description: description, color: selectedColor)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.large)
        #if os(macOS)
        .frame(width: 420, height: 340)
        #endif
    }
}
