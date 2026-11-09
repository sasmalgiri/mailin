//
//  AppLimits.swift
//  maxmailin
//
//  CAP-06 (owner, 2026-11-06: "a hidden cap is backstabbing"). Every limit
//  the app enforces, named in one place and shown in Settings ▸ Health ▸
//  Limits, with the kind of limit it is: a plan rule, a format's own
//  ceiling, a device fact, a safety budget that reports what it skipped, or
//  a previous engine kept for rollback that states its window on screen.
//  The five jobs themselves — open, folders, search, duplicates, export —
//  have no cap of the app's own; that is listed too, so the absence is a
//  statement and not a gap in the list.
//
//  `testCAP06_*` scans the five-jobs source for numeric windows and checks
//  this list names every constant it knows about.
//

@testable import ArchiveCore
import Foundation

struct AppLimit: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case plan, format, device, safety, previousEngine, none
        var label: String {
            switch self {
            case .plan: return String(localized: "Plan rule")
            case .format: return String(localized: "Format's own limit")
            case .device: return String(localized: "Device fact")
            case .safety: return String(localized: "Safety budget — reports what it skipped")
            case .previousEngine: return String(localized: "Previous engine (rollback), stated on screen")
            case .none: return String(localized: "No cap")
            }
        }
    }
    var id: String { what }
    let kind: Kind
    let what: String
    let value: String
    let why: String
}

enum AppLimits {
    /// The previous duplicate engine's window (rollback path only; the
    /// whole-archive engine is on by default). Named here so it is listed.
    static let previousEngineDuplicateWindow = 5_000

    static var all: [AppLimit] {
        let bytes = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        return [
            // The five jobs: no cap of the app's own.
            AppLimit(kind: .none, what: String(localized: "Opening archives"), value: String(localized: "no preset size or message count"),
                     why: String(localized: "Imports stream in batches sized to free memory and disk; a single message of any size is indexed by its boundaries.")),
            AppLimit(kind: .none, what: String(localized: "Folders"), value: String(localized: "every folder and label"),
                     why: String(localized: "Lists page 200 at a time with the total shown; nothing is cut.")),
            AppLimit(kind: .none, what: String(localized: "Search"), value: String(localized: "whole archive, whole texts"),
                     why: String(localized: "Bodies and attachment texts are indexed whole in 48K-character chunks; results, counts and exports walk every match.")),
            AppLimit(kind: .none, what: String(localized: "Duplicates"), value: String(localized: "whole archive"),
                     why: String(localized: "Groups are found over the whole archive and compared in full before anything is offered for removal.")),
            AppLimit(kind: .none, what: String(localized: "Exports"), value: String(localized: "whole selection, every format"),
                     why: String(localized: "Every format streams; the portable HTML viewer is written in chunks; the inventory lists every file.")),
            // Plan rules.
            AppLimit(kind: .plan, what: String(localized: "Free plan — reading and search"), value: String(localized: "newest \(StoreManager.freeEmailLimit) emails"),
                     why: AccessPolicy.afterExpiryStatement),
            AppLimit(kind: .plan, what: String(localized: "Free plan — import size"), value: bytes(Int64(StoreManager.freeInputByteLimit)),
                     why: String(localized: "Per import, under the Free plan only.")),
            AppLimit(kind: .plan, what: String(localized: "Free plan — attachment saves"), value: String(localized: "\(StoreManager.freeAttachmentDownloadsPerDay) a day"),
                     why: String(localized: "Opening attachments is never limited; saving them in bulk is, on the Free plan.")),
            AppLimit(kind: .plan, what: String(localized: "Free plan — AI questions"), value: String(localized: "\(AIAssistantView.freeQueryLimit) a day"),
                     why: String(localized: "On-device AI answers; the archive itself is never limited by this.")),
            // Formats and devices.
            AppLimit(kind: .format, what: String(localized: "Outlook PST"), value: String(localized: "warning above \(bytes(SourceSizePolicy.pstTestedCeilingBytes)); ANSI PST \(bytes(SourceSizePolicy.ansiPSTMaxBytes))"),
                     why: String(localized: "Outlook's own default maximum; mailin opens the file and says so, it does not refuse.")),
            AppLimit(kind: .format, what: String(localized: "Notes NSF"), value: String(localized: "warning between \(bytes(SourceSizePolicy.nsfLegacyMaxBytes)) and \(bytes(SourceSizePolicy.nsfModernMaxBytes))"),
                     why: String(localized: "HCL's documented ceilings for older and current Notes databases.")),
            AppLimit(kind: .device, what: String(localized: "FAT32 drives"), value: bytes(ArchiveLocationPolicy.fat32FileCeilingBytes),
                     why: String(localized: "A file system fact: one file cannot exceed 4 GiB on FAT32 (exFAT and APFS have no such ceiling); mbox exports can be split into 2 GB parts.")),
            // Safety budgets.
            AppLimit(kind: .safety, what: String(localized: "Document part or archive member, per run"), value: bytes(ExtractionLimits.base.partBytes),
                     why: String(localized: "A part or member larger than this is listed and the attachment marked partial, never silently dropped. Resume on that attachment doubles the ceiling for its next run.")),
            AppLimit(kind: .safety, what: String(localized: "Bytes read from one attachment's archives, per run"), value: bytes(ExtractionLimits.base.totalArchiveBytes),
                     why: String(localized: "All levels together. Members beyond it are listed as not read; Resume doubles the budget for the next run.")),
            AppLimit(kind: .safety, what: String(localized: "Archives inside archives, per run"), value: String(localized: "\(ExtractionLimits.base.archiveDepth) levels"),
                     why: String(localized: "Deeper archives are listed, not opened; Resume opens one more level per round.")),
            AppLimit(kind: .safety, what: String(localized: "OCR image size"), value: String(localized: "\(Int(AttachmentOCR.maxPixels)) px on the long side"),
                     why: String(localized: "Larger images are scaled down before recognition; every image is still read.")),
            AppLimit(kind: .safety, what: String(localized: "Messages inside messages, per run"), value: String(localized: "\(ExtractionLimits.base.messageDepth) levels"),
                     why: String(localized: "Deeper attached messages are listed, not opened; Resume opens one more level per round.")),
            // R5 (owner 2026-11-08: "there should be no limit at all"): no single-message ceiling.
            AppLimit(kind: .none, what: String(localized: "Single message size"), value: String(localized: "no limit"),
                     why: String(localized: "A message of any size is kept and exported byte for byte. One larger than \(bytes(OffsetImportEngine().fullParseCeilingBytes)) is read from its original file in slices after import: its text is indexed whole for search, and each attachment is streamed out of the file and read like any other attachment.")),
            // R5b: the remaining guards of the five jobs, each named with what happens at it.
            AppLimit(kind: .safety, what: String(localized: "Parts nested inside one message"), value: String(localized: "\(MIMEParser.maxRecursionDepth) levels"),
                     why: String(localized: "Deeper nesting is a sign of damage; those parts are not read, the message is kept and exported byte for byte.")),
            AppLimit(kind: .safety, what: String(localized: "One line of a mailbox"), value: bytes(Int64(OffsetMBOXScanner().maxLineBytes)),
                     why: String(localized: "A file with a longer unbroken line is not a mailbox; it is refused with that reason, never partly read.")),
            AppLimit(kind: .safety, what: String(localized: "Header block of one message"), value: bytes(Int64(OffsetMBOXScanner().maxHeaderBytes)),
                     why: String(localized: "Header fields beyond it are not read; the message, its body and its bytes are kept whole.")),
            AppLimit(kind: .safety, what: String(localized: "Mailboxes inside archives"), value: String(localized: "one archive level"),
                     why: String(localized: "A mailbox inside a ZIP, TAR or 7z is imported; one inside an archive inside an archive is counted as skipped in the import report.")),
            // CLOSE-01: the .msg (2 GB) and .emlx (500 MB) whole-file refusals are gone — both are read by
            // range through a file handle; one above the full-parse ceiling is imported like any large
            // message (the "Single message size" row above), so there is no row of their own.
            AppLimit(kind: .safety, what: String(localized: "Message recovered from damaged bytes"), value: bytes(Int64(MIMECarver.maxMessage)),
                     why: String(localized: "A message carved out of damaged data is cut there and marked truncated.")),
            AppLimit(kind: .device, what: String(localized: "RAR decoding window"), value: bytes(RARReader.maxDecoderDictionaryBytes),
                     why: String(localized: "A quarter of this device's memory, at most 4 GiB: a RAR member whose decoding window would need more is listed as not read, with the size it needs.")),
            AppLimit(kind: .safety, what: String(localized: "Pattern (regular expression) search"),
                     value: String(localized: "\(BoundedRegexSearch.literalCandidateCap) candidates, or \(BoundedRegexSearch.defaultNoLiteralScanCap) messages for a pattern without a word; patterns up to \(BoundedRegexSearch.maxPatternLength) characters"),
                     why: String(localized: "A broader pattern stops there and the results say so; each candidate is checked against its whole text.")),
            AppLimit(kind: .format, what: String(localized: "Outlook PST export"), value: String(localized: "\(bytes(Int64(PSTStreamWriter.maxFileBytes))) per file"),
                     why: String(localized: "The PST format's own maximum; a larger export is written as several PST files.")),
            // Previous engines.
            AppLimit(kind: .previousEngine, what: String(localized: "Previous duplicate engine"), value: String(localized: "newest \(previousEngineDuplicateWindow) emails"),
                     why: String(localized: "Runs only when the whole-archive engine is switched off or has stopped; the screen states the window.")),
            AppLimit(kind: .previousEngine, what: String(localized: "Previous search index"), value: String(localized: "first \(bytes(Int64(FTSSearchIndex.indexedTextBudgetBytes))) of a body"),
                     why: String(localized: "The per-year index behind the plain box when the search model is off; a message cut there says so on its search coverage. The search model reads the chunk index, which holds bodies whole.")),
            AppLimit(kind: .previousEngine, what: String(localized: "Previous mbox reader"), value: String(localized: "\(bytes(Int64(MBOXParser.maxMessageBytes))) per message"),
                     why: String(localized: "Runs only when the offset reader is switched off; a larger message is counted as skipped in the import report.")),
            AppLimit(kind: .previousEngine, what: String(localized: "Previous folder list"), value: String(localized: "\(ArchiveSidebarModel.labelLimit) busiest folders"),
                     why: String(localized: "Only when Complete lists is switched off; the complete list pages through every folder.")),
        ]
    }
}
