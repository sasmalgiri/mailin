//
//  NextBestAction.swift
//  maxmailin
//
//  Phase E — discoverability. ICIJ's Datashare team found "reporters missing
//  as much as 20% of features"; the fix is to make sure no capability is more
//  than one guided step away. This pure engine looks at what the current
//  persona has and hasn't done yet and returns the single most valuable next
//  step, with a plain reason and a one-tap destination. Unit-tested; the view
//  just renders the top suggestion as an always-visible banner.
//

import Foundation

enum NextBestAction {

    /// One recommended step. Either it jumps to a tool (`hub`) or it opens the
    /// guided Workflows tab (`opensWorkflows`) — the governance layer the
    /// persona most benefits from discovering.
    struct Suggestion: Identifiable, Equatable {
        var id: String { title }
        let icon: String
        let title: String
        let rationale: String
        let cta: String
        let hub: HubDestination?
        var opensWorkflows: Bool = false
    }

    /// Everything the engine needs — all cheaply derivable, all offline.
    struct State {
        var persona: String = "general"
        var archiveEmpty: Bool = true
        /// Has the persona ever started their guided workflow (any status)?
        var startedPersonaWorkflow: Bool = false
        /// IT: is the watch folder currently off?
        var watchFolderOff: Bool = true
        /// Legal: privileged emails still missing an annotation.
        var privilegeGaps: Int = 0
        /// Personal: exact duplicates present in the archive.
        var duplicateCount: Int = 0
    }

    /// The prioritized suggestions (most valuable first). The view shows the
    /// top one as a banner; the list is ordered so "import" always wins over
    /// "start a workflow" always wins over persona-specific discovery.
    static func suggestions(_ s: State) -> [Suggestion] {
        var out: [Suggestion] = []

        // 1. Nothing works without data — the universal first step.
        if s.archiveEmpty {
            out.append(Suggestion(
                icon: "square.and.arrow.down",
                title: "Import your first archive",
                rationale: "Bring in an .mbox, .pst, or a folder of emails — everything else in mailin works from here, entirely on this device.",
                cta: "Import", hub: .emailInbox))
            return out   // don't crowd the empty state with more
        }

        // 2. The governance layer is the thing most users don't discover — a
        //    guided run that produces the record automatically.
        if !s.startedPersonaWorkflow {
            out.append(Suggestion(
                icon: "flowchart",
                title: "Start your guided workflow",
                rationale: workflowRationale(s.persona),
                cta: "Show workflows", hub: nil, opensWorkflows: true))
        }

        // 3. Persona-specific capability that's easy to miss (the 20% lesson).
        switch s.persona {
        case "forensic":
            out.append(Suggestion(
                icon: "checkmark.seal",
                title: "Verify evidence integrity",
                rationale: "Compute and check per-email SHA-256 hashes so the chain of custody holds up — the log incomplete hashes break.",
                cta: "Open", hub: .chainOfCustody))
        case "legal":
            if s.privilegeGaps == 0 {
                out.append(Suggestion(
                    icon: "chart.bar.doc.horizontal",
                    title: "Track review velocity & privilege gaps",
                    rationale: "The Review Dashboard shows progress and flags any privileged email missing its log entry — before it becomes the gap opposing counsel finds.",
                    cta: "Open", hub: .reviewDashboard))
            }
        case "it_admin":
            if s.watchFolderOff {
                out.append(Suggestion(
                    icon: "eye",
                    title: "Turn on the watch folder",
                    rationale: "Point it at where reported emails land and they auto-import into the triage queue — no manual step per report.",
                    cta: "Open", hub: .phishingTriage))
            }
        case "journalist":
            out.append(Suggestion(
                icon: "doc.text.magnifyingglass",
                title: "Build a cited Story File",
                rationale: "Turn your annotated findings into a Markdown story where every claim carries its source email — the receipts, built as you write.",
                cta: "Open", hub: .storyFile))
        case "personal":
            if s.duplicateCount > 0 {
                out.append(Suggestion(
                    icon: "square.on.square.dashed",
                    title: "Clear \(s.duplicateCount) duplicate email\(s.duplicateCount == 1 ? "" : "s")",
                    rationale: "Overlapping imports leave exact duplicates — remove them archive-wide in one pass.",
                    cta: "Open", hub: .duplicateManager))
            }
        default:
            break
        }

        return out
    }

    private static func workflowRationale(_ persona: String) -> String {
        switch persona {
        case "forensic":
            return "The Evidence Intake & Review recipe walks NIST 800-86 — receive, hash, examine, analyze, report — and posts each document for you, so there's no custody log to write up by hand."
        case "legal":
            return "The Production Run recipe walks EDRM — assemble, code, privilege-log, Bates, produce — and won't let you produce before the privilege log is complete."
        case "it_admin":
            return "The Phishing Incident recipe walks NIST 800-61 — intake, analyze, verdict, contain, close — and posts the verdict number your ticket cites."
        case "journalist":
            return "The Story Build recipe walks ingest → verify → annotate → compile → fact-check, and produces a cited, versioned story file."
        default:
            return "A guided workflow does the whole job step by step and keeps a numbered record automatically — nothing to write up afterward."
        }
    }
}
