@testable import ArchiveCore
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

    // §3-L11: tag / classify every email in scope when the 3.0 engine is on.
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    @Environment(\.archiveScope) private var scope
    @State private var wholeScope = false
    @State private var scopeTotal: Int?
    @State private var scopeConfirm: ScopeConfirmationRequest?
    private var v3: Bool { modules?.isOn(.v3BatchOperations) ?? false }
    private var v3Whole: Bool { v3 && wholeScope }

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

            if v3 {
                Toggle(isOn: $wholeScope) {
                    Text("Apply tags and classification to every email in scope (\(scopeTotal ?? 0)), not only the selected ones")
                        .font(Typography.callout)
                }
                .padding(.horizontal, Spacing.medium)
                .padding(.top, Spacing.small)
            }
            if selectedIDs.isEmpty && !v3Whole {
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
            actionTitle: String(localized: "Remove")
        ) {
            performBulkDelete()
        }
        .featureTutorial(.batchOperations, key: "batch_operations_tutorial_seen", isPresented: $showTutorial)
        .scopeConfirmation($scopeConfirm)
        .task(id: v3) { if v3 { scopeTotal = await scope.resolvedTotal() } }
    }

    // MARK: - 3.0 whole scope

    private func runWholeScope(_ ops: [BatchOperationsEngine.Operation], title: String, verb: String, done: @escaping (Int) -> String) {
        Task { @MainActor in
            scopeConfirm = await ScopeConfirm.request(scope, title: title, verb: verb) {
                isProcessing = true
                resultMessage = nil
                defer { isProcessing = false }
                do {
                    var count = 0
                    for op in ops {
                        let r = try await BatchOperationsEngine.apply(op, scope: scope, loaded: emails.map(\.id))
                        count = r.count
                        await ScopeJob.recordReceipt(r.receipt, registry: modules)
                    }
                    withAnimation(AnimationTiming.fast) { resultMessage = done(count) }
                    clearResultAfterDelay()
                } catch {
                    resultMessage = error.localizedDescription
                }
            }
        }
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
            title: String(localized: "No Emails Selected"),
            message: String(localized: "Select one or more emails from the list, then return here to perform bulk operations.")
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
                        Text(LocalizedStringKey(category.rawValue)).tag(category)
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
                        Text(LocalizedStringKey(category.rawValue)).tag(category)
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
                        Text(LocalizedStringKey(format.rawValue)).tag(format)
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
                        Text(LocalizedStringKey(format.rawValue)).tag(format)
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
        if v3Whole {
            newTagName = ""
            runWholeScope([.add(tag)], title: String(localized: "Apply Tag"), verb: String(localized: "Tag")) {
                String(localized: "Tagged \($0) emails")
            }
            return
        }

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
        if v3Whole {
            let tag = removeTagSelection
            removeTagSelection = ""
            runWholeScope([.remove(tag)], title: String(localized: "Remove Tag"), verb: String(localized: "Remove")) {
                String(localized: "Removed “\(tag)” from \($0) emails")
            }
            return
        }

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
        if v3Whole {
            let tag = selectedCategory.rawValue
            runWholeScope([.add(tag)], title: String(localized: "Classify"), verb: String(localized: "Classify")) {
                String(localized: "Classified \($0) emails as \(tag)")
            }
            return
        }
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
        if v3Whole {
            // Removes the classification tags only — other tags stay.
            runWholeScope(BulkCategory.allCases.map { .remove($0.rawValue) },
                          title: String(localized: "Clear Classification"), verb: String(localized: "Clear")) {
                String(localized: "Cleared classification from \($0) emails")
            }
            return
        }
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

    /// Exports exactly the selected emails in the chosen format through the
    /// streamed export service (MBOX archive, signed forensic CSV, or one PDF
    /// per email). The audit entry and document are written only after the
    /// export has actually completed.
    private func performBulkExport() {
        let ids = Set(selectedEmails.map(\.id))
        guard !ids.isEmpty else { return }
        let format = exportFormat
        #if os(macOS)
        let destination: URL
        if format == .pdf {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Export Here")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        } else {
            let name = format == .mbox ? "selected_emails.mbox" : "selected_emails.csv"
            guard let url = PlatformFileSaver.savePanel(suggestedName: name) else { return }
            destination = url
        }
        #else
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batch_export_\(UUID().uuidString)")
        let destination = format == .pdf ? base
            : base.appendingPathExtension(format == .mbox ? "mbox" : "csv")
        if format == .pdf {
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        #endif

        isProcessing = true
        progressValue = 0
        resultMessage = nil
        let scope = ArchiveSelectionScope.explicit(ids)
        Task { @MainActor in
            let service = ArchiveExportService.shared
            let progress: @MainActor (Int, Int) -> Void = { done, total in
                progressValue = total > 0 ? Double(done) / Double(total) : 0
            }
            var message: String
            do {
                let result: ArchiveExportResult
                switch format {
                case .mbox: result = try await service.exportMBOXArchive(scope: scope, to: destination, onProgress: progress)
                case .csv: result = try await service.exportForensicCSV(scope: scope, to: destination, onProgress: progress)
                case .pdf: result = try await service.exportPDFFiles(scope: scope, to: destination, onProgress: progress)
                }
                if result.cancelled {
                    message = String(localized: "Export cancelled after \(result.recordsWritten) of \(ids.count) emails.")
                } else {
                    let written = result.recordsWritten
                    ForensicManager.shared.logAction(
                        "Bulk Export",
                        detail: "Exported \(written) of \(ids.count) selected email(s) as \(format.rawValue) → \(destination.lastPathComponent)")
                    await DocumentRegistry.captureStructured(.export,
                        summary: "Bulk export — \(written) emails as \(format.rawValue)",
                        document: CapturedDocument(title: String(localized: "Bulk Export"), sections: [
                          .init(name: String(localized: "Bulk Export"), fields: [
                            .init(key: "Emails selected", value: "\(ids.count)"),
                            .init(key: "Emails exported", value: "\(written)"),
                            .init(key: "Format", value: format.rawValue),
                            .init(key: "Destination", value: destination.lastPathComponent)])]),
                        refs: destination.lastPathComponent)
                    message = written == ids.count
                        ? String(localized: "Exported \(written) emails as \(format.rawValue) — \(destination.lastPathComponent)")
                        : String(localized: "Exported \(written) of \(ids.count) emails as \(format.rawValue) — the rest could not be read from the archive.")
                    #if os(iOS)
                    if case .failed(let why) = PlatformExport.share(destination) { message += " " + why }
                    #endif
                }
            } catch {
                message = String(localized: "Export failed: \(error.localizedDescription)")
            }
            progressValue = 1.0
            withAnimation(AnimationTiming.fast) {
                resultMessage = message
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
