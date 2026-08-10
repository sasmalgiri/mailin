//
//  WorkCenterModel.swift
//  maxmailin
//
//  The SAP Business Workplace idea: your work finds you. A pure model that
//  turns the app's pending records into a prioritized list of work items —
//  triage verdicts owed, review emails pending, privilege-log gaps,
//  watch-folder state, analysis coverage. Unit-tested; the view just renders.
//

import Foundation

enum WorkCenterModel {

    enum Severity: Int, Comparable {
        case critical = 0   // defensibility holes
        case action = 1     // work waiting on you
        case info = 2       // background state worth knowing
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    struct WorkItem: Identifiable, Equatable {
        var id: String { title }
        let severity: Severity
        let icon: String
        let title: String
        let detail: String
        let destination: HubDestination?
    }

    struct Inputs {
        var triagePending = 0
        var reviewPending = 0          // emails left across batches
        var batchCount = 0
        var privilegeGaps = 0
        var watchFolderActive: Bool? = nil   // nil = never configured
        var analysisAnalyzed = 0
        var analysisTotal = 0
        var digestEnabled = false
    }

    static func items(_ i: Inputs) -> [WorkItem] {
        var out: [WorkItem] = []
        if i.privilegeGaps > 0 {
            out.append(WorkItem(
                severity: .critical, icon: "exclamationmark.triangle.fill",
                title: "\(i.privilegeGaps) privileged email\(i.privilegeGaps == 1 ? "" : "s") missing annotation",
                detail: "Every withheld email needs its reason on record — close these before production.",
                destination: .reviewDashboard))
        }
        if i.triagePending > 0 {
            out.append(WorkItem(
                severity: .action, icon: "shield.lefthalf.filled",
                title: "\(i.triagePending) email\(i.triagePending == 1 ? "" : "s") awaiting triage verdict",
                detail: "User-reported suspicious emails, pre-scored and waiting for your call.",
                destination: .phishingTriage))
        }
        if i.reviewPending > 0 {
            out.append(WorkItem(
                severity: .action, icon: "rectangle.stack.badge.play",
                title: "\(i.reviewPending) email\(i.reviewPending == 1 ? "" : "s") pending review",
                detail: "Across \(i.batchCount) batch\(i.batchCount == 1 ? "" : "es") — keep the velocity up.",
                destination: .reviewDashboard))
        }
        if i.watchFolderActive == false {
            out.append(WorkItem(
                severity: .info, icon: "eye.slash",
                title: "Watch folder is off",
                detail: "New reported emails won't auto-import until you resume watching.",
                destination: .phishingTriage))
        }
        if i.analysisTotal > 0 && i.analysisAnalyzed < i.analysisTotal {
            let pct = Int((Double(i.analysisAnalyzed) / Double(i.analysisTotal) * 100).rounded())
            out.append(WorkItem(
                severity: .info, icon: "sparkles",
                title: "AI analysis \(pct)% complete",
                detail: "\(i.analysisTotal - i.analysisAnalyzed) email(s) still to analyze — runs in the background; chips and dashboards fill in as it finishes.",
                destination: nil))
        }
        return out.sorted { ($0.severity, $0.title) < ($1.severity, $1.title) }
    }
}
