//
//  BatchOperationsView.swift
//  mailin
//
//  Bulk operations panel for selected/filtered emails:
//  tagging, classification, export, and removal.
//

import SwiftUI

struct BatchOperationsView: View {
    let emails: [MBOXParser.RawEmail]
    @Binding var selectedIDs: Set<UUID>

    var onTagApplied: (String, [UUID]) -> Void
    var onExportRequested: ([MBOXParser.RawEmail], String) -> Void

    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss

    // MARK: - Tagging State

    @State private var newTagName: String = ""
    @State private var removeTagSelection: String = ""

    // MARK: - Classification State

    enum BulkCategory: String, CaseIterable, Identifiable {
        case personal = "Personal"
        case business = "Business"
        case newsletter = "Newsletter"
        case promotional = "Promotional"
        var id: String { rawValue }
    }

    @State private var selectedCategory: BulkCategory = .personal

    // MARK: - Export State

    enum ExportFormat: String, CaseIterable, Identifiable {
        case mbox = "MBOX"
        case csv = "CSV"
        case pdf = "PDF"
        var id: String { rawValue }
    }

    @State private var exportFormat: ExportFormat = .csv

    // MARK: - Progress & Results

    @State private var isProcessing = false
    @State private var progressValue: Double = 0
    @State private var resultMessage: String?

    // MARK: - Delete Confirmation

    @State private var showDeleteConfirmation = false
    @State private var deletedIDs: Set<UUID> = []
    @State private var showTutorial = false

    // MARK: - Computed Helpers

    private var selectedEmails: [MBOXParser.RawEmail] {
        emails.filter { selectedIDs.contains($0.id) }
    }

    private var allExistingTags: [String] {
        let tagSet = Set(emails.flatMap { $0.tags })
        return tagSet.sorted()
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if selectedIDs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: Spacing.medium) {
                        Label {
                            Text("Batch operations apply changes to all selected emails at once. Tags and exports can be undone; deletions are permanent. Review your selection before applying.")
                                .font(Typography.caption1)
                        } icon: {
                            Image(systemName: "gearshape.2.fill")
                                .foregroundColor(.blue)
                        }
                        .padding(Spacing.xSmall)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(CornerRadius.small)

                        selectionSummary
                        bulkTaggingSection
                        bulkClassificationSection
                        bulkExportSection
                        bulkDeleteSection
                    }
                    .padding(Spacing.medium)
                }
            }
        }
        .background(AppColors.backgroundPrimary)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 700,
               minHeight: 500, idealHeight: 650, maxHeight: 800)
        #endif
        .adaptiveDestructiveConfirmation(
            "Remove Selected Emails",
            isPresented: $showDeleteConfirmation,
            message: "This will remove \(selectedIDs.count) email(s) from the current view. The source file is not modified.",
            actionTitle: "Remove"
        ) {
            performBulkDelete()
        }
        .featureTutorial(.batchOperations, key: "batch_operations_tutorial_seen", isPresented: $showTutorial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label("Batch Operations", systemImage: "square.stack.3d.up.fill")
                    .font(Typography.title2)
                Text("Perform bulk actions on selected emails.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Batch Operations panel")

            Spacer()

            TutorialHelpButton(showTutorial: $showTutorial)

            Button {
                closeSheet()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close batch operations")
        }
        .padding(Spacing.medium)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            icon: "checklist.unchecked",
            title: "No Emails Selected",
            message: "Select one or more emails from the list, then return here to perform bulk operations."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection Summary

    private var selectionSummary: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(AppColors.success)
                Text("\(selectedIDs.count) email\(selectedIDs.count == 1 ? "" : "s") selected")
                    .font(Typography.headline)
            }

            if isProcessing {
                ProgressView(value: progressValue)
                    .accessibilityLabel("Operation progress")
                    .accessibilityValue("\(Int(progressValue * 100)) percent")
            }

            if let message = resultMessage {
                Text(message)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.success)
                    .transition(.opacity)
            }
        }
        .padding(Spacing.small)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
        .accessibilityElement(children: .combine)
        #else
        HStack(spacing: Spacing.small) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppColors.success)
            Text("\(selectedIDs.count) email\(selectedIDs.count == 1 ? "" : "s") selected")
                .font(Typography.headline)

            Spacer()

            if isProcessing {
                ProgressView(value: progressValue)
                    .frame(width: 120)
                    .accessibilityLabel("Operation progress")
                    .accessibilityValue("\(Int(progressValue * 100)) percent")
            }

            if let message = resultMessage {
                Text(message)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.success)
                    .transition(.opacity)
            }
        }
        .padding(Spacing.small)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
        .accessibilityElement(children: .combine)
        #endif
    }

    // MARK: - Bulk Tagging

    private var bulkTaggingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Bulk Tagging", systemImage: "tag.fill")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            #if os(iOS)
            VStack(spacing: Spacing.xSmall) {
                TextField("Tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New tag name")

                Button("Apply Tag") {
                    performApplyTag()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                .accessibilityLabel("Apply tag to selected emails")
            }
            #else
            HStack(spacing: Spacing.xSmall) {
                TextField("Tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New tag name")

                Button("Apply Tag") {
                    performApplyTag()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                .accessibilityLabel("Apply tag to selected emails")
                .accessibilityHint("Tags \(selectedIDs.count) selected emails with the entered tag name")
            }
            #endif

            // Remove Tag
            if !allExistingTags.isEmpty {
                HStack(spacing: Spacing.xSmall) {
                    Picker("Remove tag:", selection: $removeTagSelection) {
                        Text("Select a tag").tag("")
                        ForEach(allExistingTags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    #endif
                    .accessibilityLabel("Tag to remove")

                    Button("Remove Tag") {
                        performRemoveTag()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(removeTagSelection.isEmpty || isProcessing)
                    .accessibilityLabel("Remove selected tag from emails")
                }
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Bulk Classification

    private var bulkClassificationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Bulk Classification", systemImage: "folder.badge.gearshape")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            #if os(iOS)
            VStack(spacing: Spacing.xSmall) {
                Picker("Category:", selection: $selectedCategory) {
                    ForEach(BulkCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Classification category")

                Button("Classify Selected") {
                    performBulkClassification()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(isProcessing)
                .accessibilityLabel("Classify selected emails")
            }
            #else
            HStack(spacing: Spacing.xSmall) {
                Picker("Category:", selection: $selectedCategory) {
                    ForEach(BulkCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Classification category")

                Button("Classify Selected") {
                    performBulkClassification()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isProcessing)
                .accessibilityLabel("Classify selected emails")
                .accessibilityHint("Classifies \(selectedIDs.count) emails as \(selectedCategory.rawValue)")
            }
            #endif

            // Clear Classification
            HStack(spacing: Spacing.xSmall) {
                Button("Clear Classification") {
                    performClearClassification()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isProcessing)
                .accessibilityLabel("Clear classification from selected emails")
                .accessibilityHint("Removes category classification from \(selectedIDs.count) selected emails")
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Bulk Export

    private var bulkExportSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Bulk Export", systemImage: "square.and.arrow.up.fill")
                .font(Typography.headline)
                .accessibilityAddTraits(.isHeader)

            #if os(iOS)
            VStack(spacing: Spacing.xSmall) {
                Picker("Format:", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Export format")

                Button("Export Selected") {
                    performBulkExport()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(isProcessing)
                .accessibilityLabel("Export selected emails")
            }
            #else
            HStack(spacing: Spacing.xSmall) {
                Picker("Format:", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Export format")

                Button("Export Selected") {
                    performBulkExport()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isProcessing)
                .accessibilityLabel("Export selected emails")
                .accessibilityHint("Exports \(selectedIDs.count) emails in \(exportFormat.rawValue) format")
            }
            #endif
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Bulk Delete

    private var bulkDeleteSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Remove from View", systemImage: "trash")
                .font(Typography.headline)
                .foregroundColor(AppColors.error)
                .accessibilityAddTraits(.isHeader)

            Text("Removes selected emails from the current view. Source files are not modified.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            Button("Remove Selected from View") {
                showDeleteConfirmation = true
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isProcessing)
            .accessibilityLabel("Remove selected emails from view")
            .accessibilityHint("Shows a confirmation dialog before removing \(selectedIDs.count) emails")
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    // MARK: - Operations

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private func performApplyTag() {
        let tag = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }

        isProcessing = true
        progressValue = 0
        resultMessage = nil

        let ids = Array(selectedIDs)
        let total = Double(ids.count)

        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50000000)
            for (index, id) in ids.enumerated() {
                progressValue = Double(index + 1) / total
                _ = id // Tag application handled via callback
            }
            progressValue = 1.0
            onTagApplied(tag, ids)

            ForensicManager.shared.logAction(
                "Bulk Tag Applied",
                detail: "Tag '\(tag)' applied to \(ids.count) email(s)"
            )

            withAnimation(AnimationTiming.fast) {
                resultMessage = "Tagged \(ids.count) email\(ids.count == 1 ? "" : "s")"
                isProcessing = false
            }
            newTagName = ""

            clearResultAfterDelay()
        }
    }

    private func performRemoveTag() {
        guard !removeTagSelection.isEmpty else { return }

        isProcessing = true
        progressValue = 0
        resultMessage = nil

        let tag = removeTagSelection
        let ids = Array(selectedIDs)
        let total = Double(ids.count)

        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50000000)
            for (index, _) in ids.enumerated() {
                progressValue = Double(index + 1) / total
            }
            progressValue = 1.0

            onTagApplied("", ids) // Empty tag signals removal

            ForensicManager.shared.logAction(
                "Bulk Tag Removed",
                detail: "Tag '\(tag)' removed from \(ids.count) email(s)"
            )

            withAnimation(AnimationTiming.fast) {
                resultMessage = "Removed tag from \(ids.count) email\(ids.count == 1 ? "" : "s")"
                isProcessing = false
            }
            removeTagSelection = ""

            clearResultAfterDelay()
        }
    }

    private func performBulkClassification() {
        isProcessing = true
        progressValue = 0
        resultMessage = nil

        let classificationTag = selectedCategory.rawValue
        let ids = Array(selectedIDs)
        let total = Double(ids.count)

        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50000000)
            for (index, _) in ids.enumerated() {
                progressValue = Double(index + 1) / total
            }
            progressValue = 1.0

            onTagApplied(classificationTag, ids)

            ForensicManager.shared.logAction(
                "Bulk Classification",
                detail: "\(ids.count) email(s) classified as '\(classificationTag)'"
            )

            withAnimation(AnimationTiming.fast) {
                resultMessage = "Classified \(ids.count) email\(ids.count == 1 ? "" : "s") as \(classificationTag)"
                isProcessing = false
            }

            clearResultAfterDelay()
        }
    }

    private func performClearClassification() {
        isProcessing = true
        progressValue = 0
        resultMessage = nil

        let ids = Array(selectedIDs)
        let total = Double(ids.count)

        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50000000)
            for (index, _) in ids.enumerated() {
                progressValue = Double(index + 1) / total
            }
            progressValue = 1.0

            onTagApplied("", ids) // Empty tag signals removal

            ForensicManager.shared.logAction(
                "Bulk Classification Cleared",
                detail: "Classification removed from \(ids.count) email(s)"
            )

            withAnimation(AnimationTiming.fast) {
                resultMessage = "Cleared classification from \(ids.count) email\(ids.count == 1 ? "" : "s")"
                isProcessing = false
            }

            clearResultAfterDelay()
        }
    }

    private func performBulkExport() {
        isProcessing = true
        progressValue = 0
        resultMessage = nil

        let toExport = selectedEmails
        let format = exportFormat.rawValue

        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50000000)
            let total = Double(toExport.count)
            for (index, _) in toExport.enumerated() {
                progressValue = Double(index + 1) / total
            }
            progressValue = 1.0

            onExportRequested(toExport, format)

            ForensicManager.shared.logAction(
                "Bulk Export",
                detail: "Exported \(toExport.count) email(s) as \(format)"
            )
            // Record a numbered document of this bulk export.
            let exportCount = toExport.count
            let exportFormat = "\(format)"
            Task { await DocumentRegistry.capture(.export,
                summary: "Bulk export — \(exportCount) email\(exportCount == 1 ? "" : "s") as \(exportFormat)",
                body: "BULK EXPORT\nEmails: \(exportCount)\nFormat: \(exportFormat)\nDate: \(Date().formatted(date: .abbreviated, time: .shortened))") }

            withAnimation(AnimationTiming.fast) {
                resultMessage = "Exported \(toExport.count) email\(toExport.count == 1 ? "" : "s") as \(format)"
                isProcessing = false
            }

            clearResultAfterDelay()
        }
    }

    private func performBulkDelete() {
        isProcessing = true
        progressValue = 0
        resultMessage = nil

        let (allowed, blocked) = CustodianManager.shared.filterProtected(selectedIDs)
        deletedIDs = allowed

        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50000000)
            progressValue = 1.0

            ForensicManager.shared.logAction(
                "Bulk Remove from View",
                detail: "\(allowed.count) email(s) removed from current view, \(blocked.count) protected by legal hold"
            )

            withAnimation(AnimationTiming.fast) {
                selectedIDs.removeAll()
                if blocked.isEmpty {
                    resultMessage = "Removed \(allowed.count) email\(allowed.count == 1 ? "" : "s") from view"
                } else {
                    resultMessage = "Removed \(allowed.count) email\(allowed.count == 1 ? "" : "s"), \(blocked.count) protected by legal hold"
                }
                isProcessing = false
            }

            clearResultAfterDelay()
        }
    }

    private func clearResultAfterDelay() {
        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4000000000)
            withAnimation(AnimationTiming.fast) {
                resultMessage = nil
                progressValue = 0
            }
        }
    }
}
