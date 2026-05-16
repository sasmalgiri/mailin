//
//  WorkspaceManager.swift
//  mailin
//
//  Multi-archive workspace manager for switching between investigations.
//

import Foundation
import SwiftUI

extension Notification.Name {
    static let workspaceChanged = Notification.Name("com.mailin.workspaceChanged")
}

@MainActor
class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    @Published var workspaces: [Workspace] = []
    @Published var activeWorkspaceID: UUID?

    private let workspacesKey = "mailin.workspaces"
    private let activeWorkspaceKey = "mailin.activeWorkspaceID"

    // MARK: - Workspace Model

    struct Workspace: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var description: String
        var createdAt: Date
        var lastAccessedAt: Date
        var emailCount: Int
        var sourceFiles: [String]
        var color: String
        var isPinned: Bool

        static let availableColors = ["blue", "green", "red", "purple", "orange", "teal"]
    }

    // MARK: - Init

    private init() {
        loadWorkspaces()
    }

    // MARK: - CRUD

    @discardableResult
    func createWorkspace(name: String, description: String, color: String) -> Workspace {
        let workspace = Workspace(
            id: UUID(),
            name: name,
            description: description,
            createdAt: Date(),
            lastAccessedAt: Date(),
            emailCount: 0,
            sourceFiles: [],
            color: Workspace.availableColors.contains(color) ? color : "blue",
            isPinned: false
        )
        workspaces.append(workspace)
        saveWorkspaces()

        // Create workspace directory
        if let dir = workspaceDirectory(for: workspace.id) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return workspace
    }

    func deleteWorkspace(id: UUID) {
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceID == id {
            activeWorkspaceID = workspaces.first?.id
        }
        saveWorkspaces()

        // Remove workspace directory
        if let dir = workspaceDirectory(for: id) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func switchToWorkspace(id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        activeWorkspaceID = id
        workspaces[index].lastAccessedAt = Date()
        saveWorkspaces()

        NotificationCenter.default.post(name: .workspaceChanged, object: id)
    }

    func updateWorkspace(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index] = workspace
        saveWorkspaces()
    }

    // MARK: - Persistence

    func saveWorkspaces() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(workspaces) {
            UserDefaults.standard.set(data, forKey: workspacesKey)
        }
        if let activeID = activeWorkspaceID {
            UserDefaults.standard.set(activeID.uuidString, forKey: activeWorkspaceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeWorkspaceKey)
        }
    }

    func loadWorkspaces() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: workspacesKey),
           let loaded = try? decoder.decode([Workspace].self, from: data) {
            workspaces = loaded
        }
        if let idString = UserDefaults.standard.string(forKey: activeWorkspaceKey) {
            activeWorkspaceID = UUID(uuidString: idString)
        }
    }

    // MARK: - Helpers

    var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeWorkspaceID }
    }

    /// Workspaces sorted with pinned first, then by last accessed date.
    var sortedWorkspaces: [Workspace] {
        workspaces.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.lastAccessedAt > rhs.lastAccessedAt
        }
    }

    func workspaceDirectory(for id: UUID) -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport
            .appendingPathComponent("mailin/Workspaces", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func colorForName(_ name: String) -> SwiftUI.Color {
        switch name {
        case "blue": return .blue
        case "green": return .green
        case "red": return .red
        case "purple": return .purple
        case "orange": return .orange
        case "teal": return .teal
        default: return .blue
        }
    }
}
