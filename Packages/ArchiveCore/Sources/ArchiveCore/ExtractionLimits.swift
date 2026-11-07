//
//  ExtractionLimits.swift
//  ArchiveCore
//
//  Audit b4b502f A10 / plan v4 §13.3 (10): the ceilings one extraction run
//  works under — bytes per document part, bytes extracted from one
//  attachment's archives across all levels, and how deep archives inside
//  archives are opened. They are real memory and time bounds for ONE run,
//  stated on the Limits screen; they are not a cap on what the archive can
//  hold. A run that stops at one of them records where and why, and the
//  person can RESUME that attachment: each round doubles the ceilings (and
//  opens one more level), so a very large file is read in stages the person
//  chooses to run, never silently and never unbounded.
//
//  The extractors read `ExtractionLimits.effective`, a task-local: a resume
//  binds the next round for its own read without touching any other work.
//

import Foundation

struct ExtractionLimits: Sendable, Equatable {
    /// One XML part / one archive member read whole.
    var partBytes: Int64
    /// Bytes extracted from one attachment's archives, all levels together.
    var totalArchiveBytes: Int64
    /// Archive inside archive inside archive: this many levels are opened.
    var archiveDepth: Int

    /// Round 0 — what every ordinary indexing pass uses.
    static let base = ExtractionLimits(partBytes: 64 * 1_048_576, totalArchiveBytes: 1_073_741_824, archiveDepth: 3)

    /// Tests lower the base to make a stop happen on small fixtures.
    nonisolated(unsafe) static var baseOverride: ExtractionLimits?

    /// The limits of resume round `round` (0 = base): doubled per round, one more level per round.
    static func round(_ round: Int) -> ExtractionLimits {
        let start = baseOverride ?? base
        let factor = Int64(1) << Int64(max(0, min(round, 20)))
        return ExtractionLimits(partBytes: start.partBytes * factor, totalArchiveBytes: start.totalArchiveBytes * factor,
                                archiveDepth: start.archiveDepth + max(0, round))
    }

    @TaskLocal static var current: ExtractionLimits?

    /// What the running extraction works under.
    static var effective: ExtractionLimits { current ?? baseOverride ?? base }

    /// "64 MiB per part, 1 GiB per attachment's archives, 3 levels".
    var summary: String {
        "\(Self.bytes(partBytes)) per part, \(Self.bytes(totalArchiveBytes)) per attachment's archives, \(archiveDepth) levels"
    }

    static func bytes(_ n: Int64) -> String {
        if n % 1_073_741_824 == 0 { return "\(n / 1_073_741_824) GiB" }
        if n % 1_048_576 == 0 { return "\(n / 1_048_576) MiB" }
        return "\(n) bytes"
    }

    /// True when a recorded reason names one of these ceilings — the row can be resumed.
    static func noteNamesALimit(_ note: String?) -> Bool {
        guard let note else { return false }
        return note.contains("byte guard") || note.contains("budget") || note.contains("deeper than") || note.contains("decompression stopped")
    }
}
