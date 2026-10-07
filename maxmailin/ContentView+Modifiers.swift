@testable import ArchiveCore
//
//  ContentView+Modifiers.swift
//  maxmailin
//
//  A2: the sheet/utility modifiers and small helper views that used to sit at
//  the bottom of ContentView.swift. Moved verbatim so ContentView.swift holds
//  the shell only; nothing here changed behaviour.
//

import SwiftUI
import UniformTypeIdentifiers
import TipKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MenuTriggerModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    var onFileImport: () -> Void
    var onExport: () -> Void
    var onAuditLog: () -> Void
    var onForensicCSV: () -> Void
    var onSearch: () -> Void
    var onSelectAll: () -> Void
    var onPrint: () -> Void
    var onNewImport: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.triggerFileImport) {
                if appState.triggerFileImport { appState.triggerFileImport = false; onFileImport() }
            }
            .onChange(of: appState.triggerExport) {
                if appState.triggerExport { appState.triggerExport = false; onExport() }
            }
            .onChange(of: appState.showReplyStats) {
                if appState.showReplyStats { appState.showReplyStats = false; appState.showReplyStatsSheet = true }
            }
            .onChange(of: appState.triggerAuditLogExport) {
                if appState.triggerAuditLogExport { appState.triggerAuditLogExport = false; onAuditLog() }
            }
            .onChange(of: appState.triggerForensicCSVExport) {
                if appState.triggerForensicCSVExport { appState.triggerForensicCSVExport = false; onForensicCSV() }
            }
            .onChange(of: appState.triggerSearch) { onSearch() }
            .onChange(of: appState.triggerSelectAll) { onSelectAll() }
            .onChange(of: appState.triggerPrint) { onPrint() }
            .onChange(of: appState.triggerNewImport) { onNewImport() }
    }
}

struct AdvancedFeatureSheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel
    @ObservedObject var predictiveEngine: PredictiveCodingEngine
    @ObservedObject var custodianManager: CustodianManager
    @ObservedObject var reviewBatchManager: ReviewBatchManager
    @Binding var selectedClusterFilter: String?
    @Binding var selectedEmailIDs: Set<UUID>
    var exportVCard: () -> Void
    var exportICS: () -> Void
    var exportHashManifest: () -> Void
    var batchPrintFiltered: () -> Void
    var verifyAllEmailIntegrity: () -> Void
    var exportMSG: () -> Void
    var exportPST: () -> Void
    var exportRelativity: () -> Void
    var importFromCloud: ([MBOXParser.RawEmail]) -> Void
    var senderEmail: String

    /// Part G1: sheets that still take `[RawEmail]` are hosted over a bounded
    /// working set streamed from the store for the CURRENT query — never the
    /// resident preview arrays.
    private var currentQuery: EmailQuery { modelVM.currentArchiveQuery }

    func body(content: Content) -> some View {
        var v = AnyView(content)
        // Part O: shared progress + Cancel for streaming exports.
        v = AnyView(v.overlay(alignment: .bottom) { ExportProgressOverlayView() })
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showDuplicateManager) { _, shown in
                guard shown else { return }
                appState.showDuplicateManager = false
                ToolWindowPresenter.shared.open(title: String(localized: "Duplicates")) { AnyView(Group {
                DuplicateManagerView(model: modelVM, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Duplicates")))
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showDuplicateManager) {
                DuplicateManagerView(model: modelVM, isPresented: $appState.showDuplicateManager)
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showPredictiveCoding) { _, shown in
                guard shown else { return }
                appState.showPredictiveCoding = false
                ToolWindowPresenter.shared.open(title: String(localized: "Predictive Coding")) { AnyView(Group {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    PredictiveCodingView(emails: emails, engine: predictiveEngine, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Predictive Coding")))
                }
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showPredictiveCoding) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    PredictiveCodingView(emails: emails, engine: predictiveEngine, isPresented: $appState.showPredictiveCoding)
                }
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showCustodianPanel) { _, shown in
                guard shown else { return }
                appState.showCustodianPanel = false
                ToolWindowPresenter.shared.open(title: String(localized: "Custodians")) { AnyView(Group {
                CustodianPanelView(manager: custodianManager, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Custodians")))
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showCustodianPanel) {
                CustodianPanelView(manager: custodianManager, isPresented: $appState.showCustodianPanel)
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showReviewBatches) { _, shown in
                guard shown else { return }
                appState.showReviewBatches = false
                ToolWindowPresenter.shared.open(title: String(localized: "Review Batches")) { AnyView(Group {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    ReviewBatchPanelView(emails: emails, manager: reviewBatchManager, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Review Batches")))
                }
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showReviewBatches) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    ReviewBatchPanelView(emails: emails, manager: reviewBatchManager, isPresented: $appState.showReviewBatches)
                }
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            })
        #endif
        v = AnyView(v.onChange(of: appState.triggerExportVCard) { _, val in
                if val { appState.triggerExportVCard = false; exportVCard() }
            })
        v = AnyView(v.onChange(of: appState.triggerExportICS) { _, val in
                if val { appState.triggerExportICS = false; exportICS() }
            })
        v = AnyView(v.onChange(of: appState.triggerExportHashManifest) { _, val in
                if val { appState.triggerExportHashManifest = false; exportHashManifest() }
            })
        v = AnyView(v.onChange(of: appState.triggerExportHeadersCSV) { _, val in
                if val {
                    appState.triggerExportHeadersCSV = false
                    // Part O: streamed from the store for the current query —
                    // never the preview arrays.
                    #if os(macOS)
                    if let url = PlatformFileSaver.savePanel(suggestedName: "headers_export.csv") {
                        let scope: ArchiveSelectionScope = .query(modelVM.currentArchiveQuery, exclusions: [])
                        ExportRunCenter.shared.run(title: String(localized: "Exporting headers CSV")) {
                            _ = try? await ArchiveExportService.shared.exportHeadersCSV(
                                scope: scope, to: url,
                                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
                        }
                    }
                    #endif
                }
            })
        v = AnyView(v.onChange(of: appState.triggerBatchPrint) { _, val in
                if val { appState.triggerBatchPrint = false; batchPrintFiltered() }
            })
        v = AnyView(v.onChange(of: appState.triggerVerifyIntegrity) { _, val in
                if val { appState.triggerVerifyIntegrity = false; verifyAllEmailIntegrity() }
            })
        v = AnyView(v.onChange(of: appState.triggerExportMSG) { _, val in
                if val { appState.triggerExportMSG = false; exportMSG() }
            })
        v = AnyView(v.onChange(of: appState.triggerExportPST) { _, val in
                if val { appState.triggerExportPST = false; exportPST() }
            })
        v = AnyView(v.onChange(of: appState.triggerExportRelativity) { _, val in
                if val { appState.triggerExportRelativity = false; exportRelativity() }
            })
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showAttachmentGrid) { _, shown in
                guard shown else { return }
                appState.showAttachmentGrid = false
                ToolWindowPresenter.shared.open(title: String(localized: "Attachments")) { AnyView(Group {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    AttachmentGridView(emails: emails)
                }
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showAttachmentGrid) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    AttachmentGridView(emails: emails)
                }
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showTimeline) { _, shown in
                guard shown else { return }
                appState.showTimeline = false
                ToolWindowPresenter.shared.open(title: String(localized: "Email Timeline")) { AnyView(Group {
                // nil emails → the timeline streams the archive from the store.
                EmailTimelineView(isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Email Timeline")))
                    .resizableSheet()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showTimeline) {
                // nil emails → the timeline streams the archive from the store.
                EmailTimelineView(isPresented: $appState.showTimeline)
                    .resizableSheet()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showRelationshipGraph) { _, shown in
                guard shown else { return }
                appState.showRelationshipGraph = false
                ToolWindowPresenter.shared.open(title: String(localized: "Relationship Graph")) { AnyView(Group {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    RelationshipGraphView(emails: emails, senderEmail: senderEmail, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Relationship Graph")))
                }
                    .resizableSheet()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showRelationshipGraph) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    RelationshipGraphView(emails: emails, senderEmail: senderEmail, isPresented: $appState.showRelationshipGraph)
                }
                    .resizableSheet()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showArchiveComparison) { _, shown in
                guard shown else { return }
                appState.showArchiveComparison = false
                ToolWindowPresenter.shared.open(title: String(localized: "Archive Comparison")) { AnyView(Group {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    ArchiveComparisonSheetWrapper(archiveA: emails)
                }
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showArchiveComparison) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    ArchiveComparisonSheetWrapper(archiveA: emails)
                }
                    #if os(macOS)
                    .toolWindowFrame()
                    #else
                    .presentationDetents([.large])
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showInvestigationReport) { _, shown in
                guard shown else { return }
                appState.showInvestigationReport = false
                ToolWindowPresenter.shared.open(title: String(localized: "Investigation Reports")) { AnyView(Group {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    InvestigationReportConfigSheet(emails: emails, senderEmail: senderEmail, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Investigation Reports")))
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 350)
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showInvestigationReport) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    InvestigationReportConfigSheet(emails: emails, senderEmail: senderEmail, isPresented: $appState.showInvestigationReport)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 350)
                    #endif
            })
        #endif
        v = AnyView(v.modifier(V7SheetsModifier(appState: appState, query: currentQuery, senderEmail: senderEmail, selectedEmailIDs: $selectedEmailIDs, modelVM: modelVM)))
        return v
    }
}

// MARK: - V7 Sheets Modifier
struct V7SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    /// Part G1: the current archive query; each sheet streams its own bounded
    /// working set — no preview array is passed down.
    var query: EmailQuery
    var senderEmail: String
    @Binding var selectedEmailIDs: Set<UUID>
    @ObservedObject var modelVM: ParsedEmailListViewModel

    func body(content: Content) -> some View {
        var v = AnyView(content)
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showAutomationRules) { _, shown in
                guard shown else { return }
                appState.showAutomationRules = false
                ToolWindowPresenter.shared.open(title: String(localized: "Automation Rules")) { AnyView(Group {
                ArchiveWorkingSetView(query: query) { emails in
                    AutomationRulesView(emails: emails)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showAutomationRules) {
                ArchiveWorkingSetView(query: query) { emails in
                    AutomationRulesView(emails: emails)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showBatchOperations) { _, shown in
                guard shown else { return }
                appState.showBatchOperations = false
                ToolWindowPresenter.shared.open(title: String(localized: "Batch Operations")) { AnyView(Group {
                ArchiveWorkingSetView(query: query) { emails in
                    BatchOperationsView(
                        emails: emails,
                        selectedIDs: $selectedEmailIDs,
                        onTagApplied: { tag, ids in
                            let idArray = Array(ids)
                            if tag.isEmpty {
                                modelVM.review.clearAllTags(for: idArray)
                            } else {
                                modelVM.review.addTag(tag, to: idArray)
                            }
                        },
                        onExportRequested: { emailsToExport, format in
                            appState.triggerExport = true
                        },
                        isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Batch Operations"))
                    )
                }
                .resizableSheet()
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showBatchOperations) {
                ArchiveWorkingSetView(query: query) { emails in
                    BatchOperationsView(
                        emails: emails,
                        selectedIDs: $selectedEmailIDs,
                        onTagApplied: { tag, ids in
                            let idArray = Array(ids)
                            if tag.isEmpty {
                                modelVM.review.clearAllTags(for: idArray)
                            } else {
                                modelVM.review.addTag(tag, to: idArray)
                            }
                        },
                        onExportRequested: { emailsToExport, format in
                            appState.triggerExport = true
                        },
                        isPresented: $appState.showBatchOperations
                    )
                }
                .resizableSheet()
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showThreadSummarizer) { _, shown in
                guard shown else { return }
                appState.showThreadSummarizer = false
                ToolWindowPresenter.shared.open(title: String(localized: "Thread Summarizer")) { AnyView(Group {
                ArchiveWorkingSetView(query: query) { emails in
                    ThreadSummarizerView(threadEmails: emails, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Thread Summarizer")))
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showThreadSummarizer) {
                ArchiveWorkingSetView(query: query) { emails in
                    ThreadSummarizerView(threadEmails: emails, isPresented: $appState.showThreadSummarizer)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showSmartAlerts) { _, shown in
                guard shown else { return }
                appState.showSmartAlerts = false
                ToolWindowPresenter.shared.open(title: String(localized: "Smart Alerts")) { AnyView(Group {
                ArchiveWorkingSetView(query: query) { emails in
                    SmartAlertsView(emails: emails, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Smart Alerts")))
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 350)
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showSmartAlerts) {
                ArchiveWorkingSetView(query: query) { emails in
                    SmartAlertsView(emails: emails, isPresented: $appState.showSmartAlerts)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 350)
                    #endif
            })
        #endif
        v = AnyView(v.modifier(V7ForensicSheetsModifier(appState: appState, query: query)))
        return v
    }
}

struct V7ForensicSheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    var query: EmailQuery

    func body(content: Content) -> some View {
        var v = AnyView(content)
        #if os(macOS)
        // A workflow this large gets its OWN window (movable, resizable,
        // sits beside the list) — never a sheet pinned over the app.
        v = AnyView(v.onChange(of: appState.showEDiscovery) { _, shown in
                guard shown else { return }
                appState.showEDiscovery = false
                let capturedQuery = query
                ToolWindowPresenter.shared.open(title: String(localized: "E-Discovery Workflow")) { AnyView(Group {
                    ArchiveWorkingSetView(query: capturedQuery) { emails in
                        EDiscoveryWorkflowView(
                            emails: emails,
                            isPresented: Binding(
                                get: { true },
                                set: { if !$0 { ToolWindowPresenter.shared.close(title: String(localized: "E-Discovery Workflow")) } }
                            ))
                    }
                }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showEDiscovery) {
                ArchiveWorkingSetView(query: query) { emails in
                    EDiscoveryWorkflowView(emails: emails, isPresented: $appState.showEDiscovery)
                }
                    .resizableSheet()
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showBatesNumbering) { _, shown in
                guard shown else { return }
                appState.showBatesNumbering = false
                ToolWindowPresenter.shared.open(title: String(localized: "Bates Numbering")) { AnyView(Group {
                ArchiveWorkingSetView(query: query) { emails in
                    BatesConfigView(emails: emails)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showBatesNumbering) {
                ArchiveWorkingSetView(query: query) { emails in
                    BatesConfigView(emails: emails)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showRedaction) { _, shown in
                guard shown else { return }
                appState.showRedaction = false
                ToolWindowPresenter.shared.open(title: String(localized: "Redaction")) { AnyView(Group {
                ArchiveWorkingSetView(query: query) { emails in
                    RedactionConfigView(emails: emails, exportQuery: query)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showRedaction) {
                ArchiveWorkingSetView(query: query) { emails in
                    RedactionConfigView(emails: emails, exportQuery: query)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showGDPRReport) { _, shown in
                guard shown else { return }
                appState.showGDPRReport = false
                ToolWindowPresenter.shared.open(title: String(localized: "GDPR Compliance")) { AnyView(Group {
                ArchiveWorkingSetView(query: query) { emails in
                    GDPRReportConfigView(emails: emails, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "GDPR Compliance")))
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showGDPRReport) {
                ArchiveWorkingSetView(query: query) { emails in
                    GDPRReportConfigView(emails: emails, isPresented: $appState.showGDPRReport)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showChainOfCustody) { _, shown in
                guard shown else { return }
                appState.showChainOfCustody = false
                ToolWindowPresenter.shared.open(title: String(localized: "Chain of Custody")) { AnyView(Group {
                ArchiveWorkingSetView(query: query) { emails in
                    ChainOfCustodyView(emails: emails, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Chain of Custody")))
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showChainOfCustody) {
                ArchiveWorkingSetView(query: query) { emails in
                    ChainOfCustodyView(emails: emails, isPresented: $appState.showChainOfCustody)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            })
        #endif
        return v
    }
}

// MARK: - V8 Sheets Modifier (Intelligence & Polish)
struct V8SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel

    func body(content: Content) -> some View {
        var v = AnyView(content)
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showNearDuplicates) { _, shown in
                guard shown else { return }
                appState.showNearDuplicates = false
                ToolWindowPresenter.shared.open(title: String(localized: "Near-Duplicates")) { AnyView(Group {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    NearDuplicateDetectionView(emails: emails, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Near-Duplicates")))
                }
                    .resizableSheet()
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showNearDuplicates) {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    NearDuplicateDetectionView(emails: emails, isPresented: $appState.showNearDuplicates)
                }
                    .resizableSheet()
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showAnomalyDetection) { _, shown in
                guard shown else { return }
                appState.showAnomalyDetection = false
                ToolWindowPresenter.shared.open(title: String(localized: "Anomaly Detection")) { AnyView(Group {
                AnomalyDetectionView(isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Anomaly Detection")))
                    .resizableSheet()
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showAnomalyDetection) {
                AnomalyDetectionView(isPresented: $appState.showAnomalyDetection)
                    .resizableSheet()
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showSmartAutoTagger) { _, shown in
                guard shown else { return }
                appState.showSmartAutoTagger = false
                ToolWindowPresenter.shared.open(title: String(localized: "Smart Auto-Tagger")) { AnyView(Group {
                SmartAutoTaggerView(isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Smart Auto-Tagger")))
                    .resizableSheet()
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showSmartAutoTagger) {
                SmartAutoTaggerView(isPresented: $appState.showSmartAutoTagger)
                    .resizableSheet()
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showAIDigest) { _, shown in
                guard shown else { return }
                appState.showAIDigest = false
                ToolWindowPresenter.shared.open(title: String(localized: "AI Digest")) { AnyView(Group {
                // Zero-array digest: the generator streams a bounded working
                // set of the selected period from the store itself.
                AIDigestView(isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "AI Digest")))
                    .resizableSheet()
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showAIDigest) {
                // Zero-array digest: the generator streams a bounded working
                // set of the selected period from the store itself.
                AIDigestView(isPresented: $appState.showAIDigest)
                    .resizableSheet()
            })
        #endif
        return v
    }
}

// MARK: - V9 Sheets Modifier (Dashboard, Security & Workspaces)
struct V9SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel
    var senderEmail: String

    func body(content: Content) -> some View {
        var v = AnyView(content)
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showExecutiveDashboard) { _, shown in
                guard shown else { return }
                appState.showExecutiveDashboard = false
                ToolWindowPresenter.shared.open(title: String(localized: "Executive Dashboard")) { AnyView(Group {
                // Query injection: the dashboard streams the current scope
                // from SQLite in bounded pages (no array plumbing).
                ExecutiveDashboardView(query: modelVM.currentArchiveQuery, isPresented: ToolWindowPresenter.closeBinding(title: "Executive Dashboard"))
                    .resizableSheet()
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showExecutiveDashboard) {
                // Query injection: the dashboard streams the current scope
                // from SQLite in bounded pages (no array plumbing).
                ExecutiveDashboardView(query: modelVM.currentArchiveQuery, isPresented: $appState.showExecutiveDashboard)
                    .resizableSheet()
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showReportBuilder) { _, shown in
                guard shown else { return }
                appState.showReportBuilder = false
                ToolWindowPresenter.shared.open(title: String(localized: "Report Builder")) { AnyView(Group {
                ReportBuilderView(isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Report Builder")))
                    .resizableSheet()
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showReportBuilder) {
                ReportBuilderView(isPresented: $appState.showReportBuilder)
                    .resizableSheet()
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showKeywordMonitor) { _, shown in
                guard shown else { return }
                appState.showKeywordMonitor = false
                ToolWindowPresenter.shared.open(title: String(localized: "Keyword Monitor")) { AnyView(Group {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    KeywordMonitorView(emails: emails, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Keyword Monitor")))
                }
                    .resizableSheet()
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showKeywordMonitor) {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    KeywordMonitorView(emails: emails, isPresented: $appState.showKeywordMonitor)
                }
                    .resizableSheet()
            })
        #endif
        #if os(macOS)
        v = AnyView(v.onChange(of: appState.showCommunicationPatterns) { _, shown in
                guard shown else { return }
                appState.showCommunicationPatterns = false
                ToolWindowPresenter.shared.open(title: String(localized: "Communication Patterns")) { AnyView(Group {
                CommunicationPatternsView(senderEmail: senderEmail, isPresented: ToolWindowPresenter.closeBinding(title: String(localized: "Communication Patterns")))
                    .resizableSheet()
            }) }
            })
        #else
        v = AnyView(v.sheet(isPresented: $appState.showCommunicationPatterns) {
                CommunicationPatternsView(senderEmail: senderEmail, isPresented: $appState.showCommunicationPatterns)
                    .resizableSheet()
            })
        #endif
        v = AnyView(v.modifier(V9UtilitySheetsModifier(appState: appState, modelVM: modelVM)))
        return v
    }
}

struct V9UtilitySheetsModifier: ViewModifier {
    /// §3.3 R1: needed for the stale-invocation guard in `handleCommand`.
    @Environment(ModuleRegistry.self) private var modules

    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel
    @EnvironmentObject private var storeManager: StoreManager

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showWorkspaceManager) {
                WorkspaceManagerView(isPresented: $appState.showWorkspaceManager)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showCommandPalette) {
                CommandPaletteView { command in
                    appState.showCommandPalette = false
                    handleCommand(command)
                }
                .resizableSheet()
            }
            .sheet(isPresented: $appState.showKeyboardShortcuts) {
                KeyboardShortcutOverlayView()
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showWhatsNew) {
                WhatsNewView()
                    .resizableSheet()
            }
            #if os(macOS)
            .onChange(of: appState.showAllAttachmentsGallery) { _, shown in
                guard shown else { return }
                appState.showAllAttachmentsGallery = false
                ToolWindowPresenter.shared.open(title: String(localized: "Attachment Gallery")) { AnyView(Group {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    AllAttachmentsGalleryView(emails: emails)
                }
                    .resizableSheet()
            }) }
            }
            #else
            .sheet(isPresented: $appState.showAllAttachmentsGallery) {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    AllAttachmentsGalleryView(emails: emails)
                }
                    .resizableSheet()
            }
            #endif
            #if os(macOS)
            .onChange(of: appState.showIOCExtractor) { _, shown in
                guard shown else { return }
                appState.showIOCExtractor = false
                ToolWindowPresenter.shared.open(title: String(localized: "IOC Extractor")) { AnyView(Group {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    IOCExtractorView(emails: emails)
                }
                    .resizableSheet()
            }) }
            }
            #else
            .sheet(isPresented: $appState.showIOCExtractor) {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    IOCExtractorView(emails: emails)
                }
                    .resizableSheet()
            }
            #endif
            .sheet(isPresented: $appState.showGuidedSearch) {
                GuidedSearchView(searchText: $modelVM.searchText, isPresented: $appState.showGuidedSearch, onSearch: {
                    modelVM.searchTextDidChange()
                })
                    .resizableSheet()
            }
    }

    /// Which page owns a palette command id, for the stale-invocation guard.
    static func commandOwner(_ id: String) -> AppModule? {
        switch id {
        case "askAI", "topicClusters", "predictiveCoding", "smartAlerts",
             "anomalyDetection", "smartAutoTagger", "aiDigest", "keywordMonitor":
            return .aiInsights
        case "forensicMode", "eDiscovery", "batesNumbering", "redaction",
             "gdprReport", "chainOfCustody", "custodianManager", "reviewBatches",
             "investigationReport", "reportBuilder", "iocExtractor":
            return .professional
        default:
            return nil
        }
    }

    private func handleCommand(_ id: String) {
        // §3.3 R1: the palette already filters by page, so reaching here for a
        // disabled page means a stale invocation (an old keyboard shortcut, a
        // restored sheet). Drop it quietly rather than tripping the state gate.
        if let owner = Self.commandOwner(id), !modules.isEnabled(owner) { return }
        switch id {
        case "askAI":
            if storeManager.requirePremium() { appState.showAIAssistant = true }
        case "analytics":
            if storeManager.requirePremium() { appState.showAnalytics = true }
        case "topicClusters":
            if storeManager.requirePremium() { withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .topics ? nil : .topics } }
        case "duplicates":
            if storeManager.requirePremium() { appState.showDuplicateManager = true }
        case "predictiveCoding":
            if storeManager.requireProfessional() { appState.showPredictiveCoding = true }
        case "timeline":
            if storeManager.requirePremium() { appState.showTimeline = true }
        case "relationshipGraph":
            if storeManager.requirePremium() { appState.showRelationshipGraph = true }
        case "smartAlerts":
            if storeManager.requirePremium() { appState.showSmartAlerts = true }
        case "anomalyDetection":
            if storeManager.requirePremium() { appState.showAnomalyDetection = true }
        case "autoTagger":
            if storeManager.requirePremium() { appState.showSmartAutoTagger = true }
        case "emailDigest":
            if storeManager.requirePremium() { appState.showAIDigest = true }
        case "nearDuplicates":
            if storeManager.requirePremium() { appState.showNearDuplicates = true }
        case "commPatterns":
            if storeManager.requirePremium() { appState.showCommunicationPatterns = true }
        case "dashboard":
            if storeManager.requirePremium() { appState.showExecutiveDashboard = true }
        case "keywordMonitor":
            if storeManager.requirePremium() { appState.showKeywordMonitor = true }
        case "reportBuilder":
            if storeManager.requirePremium() { appState.showReportBuilder = true }
        case "eDiscovery":
            if storeManager.requireProfessional() { appState.showEDiscovery = true }
        case "batesNumbering":
            if storeManager.requireProfessional() { appState.showBatesNumbering = true }
        case "redaction":
            if storeManager.requireProfessional() { appState.showRedaction = true }
        case "gdprReport":
            if storeManager.requireProfessional() { appState.showGDPRReport = true }
        case "chainOfCustody":
            if storeManager.requireProfessional() { appState.showChainOfCustody = true }
        case "forensicMode":
            ForensicManager.shared.isEnabled.toggle()
        case "custodianManager":
            if storeManager.requireProfessional() { appState.showCustodianPanel = true }
        case "reviewBatches":
            if storeManager.requireProfessional() { appState.showReviewBatches = true }
        case "investigationReport":
            if storeManager.requireProfessional() { appState.showInvestigationReport = true }
        case "exportFiltered":
            appState.triggerExport = true
        case "exportVCard":
            appState.triggerExportVCard = true
        case "exportICS":
            appState.triggerExportICS = true
        case "exportMSG":
            appState.triggerExportMSG = true
        case "exportPST":
            appState.triggerExportPST = true
        case "exportRelativity":
            appState.triggerExportRelativity = true
        case "workspaces": appState.showWorkspaceManager = true
        case "toggleSidebar": appState.toggleSidebar()
        case "allAttachments": appState.showAllAttachmentsGallery = true
        case "iocExtractor":
            if storeManager.requireProfessional() { appState.showIOCExtractor = true }
        case "guidedSearch": appState.showGuidedSearch = true
        default: break
        }
    }
}

// MARK: - Archive Comparison Sheet Wrapper
struct ArchiveComparisonSheetWrapper: View {
    /// Kept for call-site compatibility; the comparison itself reads the
    /// WHOLE current archive from the store (v2.1 backlog #3), not this
    /// working set.
    let archiveA: [MBOXParser.RawEmail]
    @State private var secondArchiveURL: URL?
    @State private var secondArchiveIsScoped = false
    @State private var showFilePicker = false
    @State private var importError: String?
    @AppStorage("defaultSenderEmail") private var defaultSenderEmail = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let secondArchiveURL {
            ArchiveComparisonView(
                secondArchiveURL: secondArchiveURL,
                nameA: "Current Archive",
                nameB: secondArchiveURL.lastPathComponent,
                senderEmail: defaultSenderEmail
            )
            .onDisappear {
                if secondArchiveIsScoped { secondArchiveURL.stopAccessingSecurityScopedResource() }
            }
        } else {
            VStack(spacing: Spacing.large) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.largeTitle)
                    .foregroundColor(AppColors.primary)

                Text("Archive Comparison")
                    .font(Typography.title2)

                Text("Compare your whole current archive with a second mailbox file (.mbox, .eml, .pst, a ZIP of mailboxes, …). Nothing is imported; both sides are compared by Message-ID and by subject, sender and minute.")
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                if let error = importError {
                    Text(error)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.error)
                }

                HStack(spacing: Spacing.medium) {
                    Button("Choose Second Archive...") {
                        showFilePicker = true
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(Spacing.xLarge)
            #if os(macOS)
            .frame(minWidth: 450, minHeight: 300)
            #endif
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: ParserFactory.allSupportedExtensions
                    .compactMap { UTType(filenameExtension: $0) },
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    // The scope stays open for the comparison's lifetime and
                    // is released when the comparison view disappears.
                    secondArchiveIsScoped = url.startAccessingSecurityScopedResource()
                    importError = nil
                    secondArchiveURL = url
                case .failure(let error):
                    importError = "Failed to select file: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Investigation Report Configuration Sheet
struct InvestigationReportConfigSheet: View {
    let emails: [MBOXParser.RawEmail]
    let senderEmail: String
    var isPresented: Binding<Bool>?
    @ObservedObject private var forensicManager = ForensicManager.shared
    @EnvironmentObject var storeManager: StoreManager
    @Environment(\.dismiss) private var envDismiss

    @State private var examinerName: String = ""
    @State private var reportTitle: String = "Email Investigation Report"
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var selectedEmailIDs: Set<UUID> = []
    @State private var showEmailSelector = false
    @State private var emailSearchText = ""
    @State private var generatedPDFData: Data?
    @State private var showFileExporter = false
    @State private var savedSuccessfully = false

    private var matchingEmails: [MBOXParser.RawEmail] {
        guard !emailSearchText.isEmpty else { return emails }
        let query = emailSearchText.lowercased()
        return emails.filter {
            ($0.headers["From"] ?? "").lowercased().contains(query) ||
            ($0.headers["Subject"] ?? "").lowercased().contains(query) ||
            ($0.headers["To"] ?? "").lowercased().contains(query)
        }
    }

    private var selectedEmails: [MBOXParser.RawEmail] {
        emails.filter { selectedEmailIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(AppColors.primary)
                Text("Generate Investigation Report")
                    .font(Typography.headline)
                Spacer()
                Button { closeSheet() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        Text("Report Configuration")
                            .font(Typography.callout)
                            .fontWeight(.semibold)

                        TextField("Report Title", text: $reportTitle)
                            .textFieldStyle(.roundedBorder)
                        TextField("Investigator / Examiner Name", text: $examinerName)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // Email Selection
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        HStack {
                            Text("Email Selection")
                                .font(Typography.callout)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(selectedEmailIDs.count) of \(emails.count) selected")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }

                        HStack(spacing: Spacing.small) {
                            Button("Select All") {
                                selectedEmailIDs = Set(emails.map(\.id))
                            }
                            .buttonStyle(CompactSecondaryButtonStyle())
                            .disabled(selectedEmailIDs.count == emails.count)

                            Button("Deselect All") {
                                selectedEmailIDs.removeAll()
                            }
                            .buttonStyle(CompactSecondaryButtonStyle())
                            .disabled(selectedEmailIDs.isEmpty)

                            Spacer()

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showEmailSelector.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(showEmailSelector ? String(localized: "Hide Emails") : String(localized: "Choose Emails"))
                                        .font(Typography.caption1)
                                    Image(systemName: showEmailSelector ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9))
                                }
                            }
                            .buttonStyle(CompactSecondaryButtonStyle())
                        }

                        if showEmailSelector {
                            VStack(spacing: Spacing.xSmall) {
                                TextField("Search emails...", text: $emailSearchText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Typography.caption1)

                                ScrollView {
                                    LazyVStack(spacing: 0) {
                                        ForEach(matchingEmails, id: \.id) { email in
                                            emailSelectionRow(email)
                                        }
                                    }
                                }
                                .frame(maxHeight: 200)
                                .background(AppColors.backgroundSecondary)
                                .cornerRadius(CornerRadius.small)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        Text("Report Contents")
                            .font(Typography.callout)
                            .fontWeight(.semibold)

                        Group {
                            Label("Title page with case info", systemImage: "doc.text")
                            Label("Executive summary with NLP analysis", systemImage: "text.magnifyingglass")
                            Label("Email timeline (monthly volume chart)", systemImage: "chart.bar")
                            Label("Top contacts table", systemImage: "person.2")
                            Label("Category breakdown", systemImage: "folder")
                            Label("Evidence tags summary", systemImage: "tag")
                            Label("Flagged / important emails", systemImage: "flag")
                        }
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    }

                    Divider()

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(AppColors.info)
                        Text("Report will analyze \(selectedEmailIDs.count) email\(selectedEmailIDs.count == 1 ? "" : "s") and generate a multi-page PDF.")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }

                    if let error = generationError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(AppColors.error)
                            Text(error)
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.error)
                        }
                    }

                    if savedSuccessfully {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Report saved. You can save it again, or generate another below.")
                                .font(Typography.caption1)
                                .foregroundColor(.green)
                        }
                    } else if generatedPDFData != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Report generated. Save it, or generate another.")
                                .font(Typography.caption1)
                                .foregroundColor(.green)
                        }
                    }

                    HStack(spacing: Spacing.small) {
                        Spacer()
                        if savedSuccessfully {
                            // Post-save: let the user reuse the window.
                            Button("Generate Another") { resetForNewReport() }
                                .buttonStyle(SecondaryButtonStyle())
                            Button {
                                showFileExporter = true
                            } label: {
                                HStack(spacing: Spacing.xSmall) {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Save Again")
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(generatedPDFData == nil)
                            Button("Done") { closeSheet() }
                                .buttonStyle(PrimaryButtonStyle())
                        } else if generatedPDFData != nil {
                            // Generated, not yet saved.
                            Button("Generate Another") { resetForNewReport() }
                                .buttonStyle(SecondaryButtonStyle())
                            Button {
                                showFileExporter = true
                            } label: {
                                HStack(spacing: Spacing.xSmall) {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Save PDF")
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        } else {
                            // Config state.
                            Button("Cancel") { closeSheet() }
                                .buttonStyle(SecondaryButtonStyle())
                            Button {
                                generateReport()
                            } label: {
                                HStack(spacing: Spacing.xSmall) {
                                    if isGenerating {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .frame(width: 16, height: 16)
                                    }
                                    Text(isGenerating ? String(localized: "Generating...") : String(localized: "Generate PDF Report"))
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(isGenerating || selectedEmailIDs.isEmpty)
                        }
                    }
                }
                .padding(Spacing.medium)
            }
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: InvestigationPDFExportFile(data: generatedPDFData),
            contentType: .pdf,
            defaultFilename: pdfFileName
        ) { result in
            switch result {
            case .success:
                forensicManager.logAction("Investigation Report", detail: "Generated PDF report for \(selectedEmailIDs.count) emails")
                // Keep the generated data so the user can Save Again to
                // another location without regenerating.
                savedSuccessfully = true
                // Capture a numbered, referable document of this job.
                let count = selectedEmailIDs.count
                let title = reportTitle
                let examiner = examinerName
                Task { await DocumentRegistry.captureStructured(.report,
                    summary: "Investigation Report: \(title) — \(count) emails",
                    document: CapturedDocument(title: title, sections: [
                      .init(name: String(localized: "Investigation Report"), fields: [
                        .init(key: "Title", value: title),
                        .init(key: "Examiner", value: examiner.isEmpty ? "—" : examiner),
                        .init(key: "Emails analyzed", value: "\(count)"),
                        .init(key: "Sections", value: "title page · executive summary · timeline · top contacts · category breakdown · evidence tags · flagged")
                      ])])) }
            case .failure(let error):
                generationError = "Failed to save: \(error.localizedDescription)"
            }
        }
        .onAppear {
            selectedEmailIDs = Set(emails.map(\.id))
            examinerName = forensicManager.examinerName
            if !forensicManager.caseNumber.isEmpty {
                reportTitle = "Case \(forensicManager.caseNumber) — Investigation Report"
            }
        }
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    /// Return the window to the configuration state so another report can be
    /// generated without closing and reopening.
    private func resetForNewReport() {
        savedSuccessfully = false
        generatedPDFData = nil
        generationError = nil
    }

    private var pdfFileName: String {
        let safeName = reportTitle.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
        return safeName
    }

    private func emailSelectionRow(_ email: MBOXParser.RawEmail) -> some View {
        let isSelected = selectedEmailIDs.contains(email.id)
        let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        let subject = email.headers["Subject"] ?? "(No Subject)"

        return Button {
            if isSelected {
                selectedEmailIDs.remove(email.id)
            } else {
                selectedEmailIDs.insert(email.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? AppColors.primary : AppColors.secondary)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(from)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(subject)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(email.headers["Date"]?.prefix(16) ?? "")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func generateReport() {
        isGenerating = true
        generationError = nil

        let reportEmails = selectedEmails
        let title = reportTitle
        let investigator = examinerName

        Task.detached(priority: .userInitiated) {
            let pdfData = await InvestigationReportGenerator.generateReport(
                emails: reportEmails,
                title: title,
                investigatorName: investigator
            )

            await MainActor.run {
                isGenerating = false
                guard !pdfData.isEmpty else {
                    generationError = "Failed to generate PDF report."
                    return
                }
                generatedPDFData = pdfData
            }
        }
    }
}

struct InvestigationPDFExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init?(data: Data?) {
        guard let data, !data.isEmpty else { return nil }
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Email Management Modifier

struct EmailManagementModifier: ViewModifier {
    @ObservedObject var modelVM: ParsedEmailListViewModel
    @Binding var selectedEmailIDs: Set<UUID>

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deleteCurrentEmail)) { notification in
                if let emailID = notification.object as? UUID {
                    modelVM.deleteEmail(emailID)
                    selectedEmailIDs.remove(emailID)
                    modelVM.applyFilters()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .archiveCurrentEmail)) { notification in
                if let emailID = notification.object as? UUID {
                    modelVM.archiveEmail(emailID)
                    selectedEmailIDs.remove(emailID)
                    modelVM.applyFilters()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadCurrentEmail)) { notification in
                if let emailID = notification.object as? UUID {
                    modelVM.toggleRead(emailID)
                }
            }
    }
}

// MARK: - InfoBanner
struct InfoBanner: View {
    var text: String
    var color: Color = AppColors.primary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: Spacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundColor(.white)
            }
            Text(text)
                .font(Typography.callout)
                .foregroundColor(.white)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xSmall)
        .background(color.opacity(0.95))
        .cornerRadius(CornerRadius.medium)
        .shadow(color: .black.opacity(0.08), radius: Shadows.medium.radius, y: Shadows.medium.y)
        .padding(.horizontal, Spacing.medium)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(AnimationTiming.normal, value: text)
    }
}

// MARK: - VisualEffectBlur for Modern Blur Background
#if os(macOS)
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .windowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
}
#else
struct VisualEffectBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let blur = UIBlurEffect(style: .systemMaterial)
        return UIVisualEffectView(effect: blur)
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) { }
}
#endif

// MARK: - Sidebar Section Header
struct SidebarSectionHeader: View {
    let title: String
    let icon: String
    var color: Color = AppColors.primary
    var helpText: String? = nil

    var body: some View {
        HStack(spacing: Spacing.xxSmall) {
            Image(systemName: icon)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(color)
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(color.opacity(0.8))
                .tracking(0.5)
            if let helpText {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundColor(AppColors.secondary.opacity(0.5))
                    .help(helpText)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(title)
    }
}

// MARK: - Feature Badge
struct FeatureBadge: View {
    let icon: String
    let text: String
    var color: Color = AppColors.primary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .adaptiveIconGradient(colors: [color, color.opacity(0.6)])
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xxSmall)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.15), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Audit Trail Sheet


#if os(iOS)
struct ReviewImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onCompletion: (Result<[URL], Error>) -> Void

    func body(content: Content) -> some View {
        content.background(
            Color.clear.fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false,
                onCompletion: onCompletion
            )
        )
    }
}
#endif
