# X1 — tool hosts inventory (2026-10-10)

## Decision and what was done (owner, 2026-10-11: "going with your suggestion")

- **No entry point removed.** Every button, menu item and palette entry still opens its tool.
- **One scope rule everywhere** (`maxmailin/ToolScope.swift`): every host — sidebar, Professional / AI page,
  tool window, iOS sheet — opens the tool on the Archive page's current filter, with a visible
  "Current filter · N emails | Whole archive · M emails" choice (both counts shown before anything runs).
  The Professional page used to open everything on the whole archive, and the AI Digest / Report Builder /
  Email Analytics from the sidebar or a menu ignored the filter.
- **One construction per Professional tool**: the Archive sidebar now builds the 15 Professional-page tools through
  `ProfessionalDestinationView`, the same view the Professional page uses (test
  `testProfessionalTools_haveOneConstruction` keeps it that way).
- The AI Insights page keeps its own source/date scope picker (already visible and explicit).
- The "×3" counts for Email Analytics and Reply Stats in the list view are per-platform presentations of one tool
  (macOS inspector, iOS sheets), not duplicate entry points; nothing to remove.


Generated from the code: every place a tool view is constructed. Tools with more than one host are listed;
the same tool opened from different places today gets **different scopes** (sidebar hub = the current filter;
Professional / AI page = the whole archive; tool windows = the query passed by the menu).

**Proposal (owner decision — removes entry points, not reversible by a switch):** keep ONE host per tool —
the page entry (Professional / AI Insights), opening on the current filter with a visible "whole archive" toggle,
and route menus, the command palette and the sidebar to it. The macOS tool window and iOS sheet stay as
presentations of that same host (one construction function per tool).

| Tool | Constructions | Hosts |
|---|---|---|
| ACHMatrixStudioView | 2 | Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| AIAssistantView | 6 | AIAssistantView.swift ×1; AI page ×1; AIWindowManager.swift ×2; sidebar hub (current filter) ×2 |
| AIDigestView | 4 | tool window / sheet ×2; AI page ×1; sidebar hub (current filter) ×1 |
| ActionRegisterStudioView | 2 | Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| AnomalyDetectionView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| ArchiveComparisonSheetWrapper | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| AttachmentGridView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| AutomationRulesView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| BatchOperationsView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| BatesConfigView | 4 | tool window / sheet ×2; Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| ChainOfCustodyView | 4 | tool window / sheet ×2; Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| CommunicationPatternsView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| CustodianPanelView | 4 | tool window / sheet ×2; Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| DuplicateManagerView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| EDiscoveryWorkflowView | 4 | tool window / sheet ×2; Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| EmailAnalyticsView | 6 | sidebar hub (current filter) ×3; ParsedEmailListView.swift ×3 |
| EmailTimelineView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| EvidenceDesksStudioView | 2 | Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| ExecutiveDashboardView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| FactEvidenceStudioView | 2 | Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| ForensicReviewView | 2 | sidebar hub (current filter) ×1; ParsedEmailListView.swift ×1 |
| GDPRReportConfigView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| IOCExtractorView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| InvestigationReportConfigSheet | 4 | tool window / sheet ×2; Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| KeywordMonitorView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| NearDuplicateDetectionView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| PIIReportView | 3 | ParsedEmailListView.swift ×2; EDiscoveryWorkflowView.swift ×1 |
| PredictiveCodingView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| ReasoningStudioView | 2 | Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| RedactionConfigView | 4 | tool window / sheet ×2; Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| RelationshipGraphView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| ReplyStatsView | 5 | sidebar hub (current filter) ×2; ParsedEmailListView.swift ×3 |
| ReportBuilderView | 4 | tool window / sheet ×2; AI page ×1; sidebar hub (current filter) ×1 |
| ReviewBatchPanelView | 4 | tool window / sheet ×2; Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| ReviewDashboardView | 2 | Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| SmartAlertsView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| SmartAutoTaggerView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| StoryFileView | 2 | Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| ThreadSummarizerView | 3 | tool window / sheet ×2; sidebar hub (current filter) ×1 |
| TriageQueueView | 2 | Professional page (whole archive) ×1; sidebar hub (current filter) ×1 |
| WorkCenterView | 4 | Professional page (whole archive) ×2; sidebar hub (current filter) ×2 |
| WorkflowRunnerView | 3 | MainNavigationHubView.swift ×1; WorkCenterView.swift ×1; WorkflowWindow.swift ×1 |
| WorkspaceManagerView | 2 | tool window / sheet ×1; sidebar hub (current filter) ×1 |

43 tools have more than one host.
