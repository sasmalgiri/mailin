//
//  ExportRequest.swift
//  ArchiveCore
//
//  The export option, request and format types shared by the writers and the app's
//  pre-flight sheet / runner.
//

import Foundation

enum UnifiedExportFormat: String, Codable, CaseIterable, Sendable {
    case word, csv, json, printText, markdown, headersCSV, mbox   // single documents
    case emlFiles, pdfFiles, tiffFiles, msgFiles                  // one file per email
    case portableHTML                    // folder with index.html viewer
    case vcard, ics                      // derived extracts
}

// MARK: - Options

enum ExportFolderLayout: String, Codable, CaseIterable, Sendable {
    case flat
    case byYear

    var label: String {
        switch self {
        case .flat: return "One folder"
        case .byYear: return "A folder per year"
        }
    }
}

enum ExportCollisionRule: String, Codable, CaseIterable, Sendable {
    case skipExisting
    case overwrite
    case keepBoth

    var label: String {
        switch self {
        case .skipExisting: return "Skip files that already exist"
        case .overwrite: return "Replace files that already exist"
        case .keepBoth: return "Keep both (add a number)"
        }
    }
}

/// How a writer should treat the destination and an interrupted run.
struct ExportWriteOptions: Codable, Equatable, Sendable {
    /// Scope positions already written by an interrupted run; stepped over.
    var skipFirst: Int = 0
    /// Single documents: continue the existing file instead of recreating it.
    var append: Bool = false
    /// Keep partial output on cancel/error so the run can be resumed.
    var keepPartialOnCancel: Bool = false
    var layout: ExportFolderLayout = .flat
    var collision: ExportCollisionRule = .overwrite
}

/// The user's pre-flight choices.
struct ExportOptions: Codable, Equatable, Sendable {
    var layout: ExportFolderLayout = .flat
    var collision: ExportCollisionRule = .overwrite
    /// Folder formats: also copy every attachment into `Attachments/`.
    var includeAttachmentsFolder: Bool = false
    /// mbox: split into ≤ 2 GB partitions (exFAT-safe, Apple Mail imports a folder).
    var partitionMBOX: Bool = false
}

// MARK: - Request

/// Everything needed to run — or later resume — one export. Codable so a
/// receipt can carry it.
struct ExportRequest: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var format: UnifiedExportFormat
    var title: String
    var scope: ArchiveSelectionScope
    var destination: String
    var isFolder: Bool
    /// Free-tier cap, nil when unlimited.
    var cap: Int?
    var options: ExportOptions = ExportOptions()
    /// Resume: positions already written by the interrupted run.
    var skipFirst: Int = 0
    /// Count known when the request was built (menu headline); nil = unknown.
    var emailCountHint: Int?

    var destinationURL: URL { URL(fileURLWithPath: destination) }

    /// Formats whose partial output can be continued. JSON and Word carry a
    /// trailer, the HTML viewer regenerates its index, vCard/ICS are derived
    /// extracts — none of those can be appended to.
    var isResumable: Bool {
        switch format {
        case .emlFiles, .pdfFiles, .tiffFiles, .msgFiles: return true
        case .csv, .headersCSV, .printText, .markdown: return true
        case .mbox: return !options.partitionMBOX
        case .word, .json, .portableHTML, .vcard, .ics: return false
        }
    }

    var writeOptions: ExportWriteOptions {
        ExportWriteOptions(skipFirst: skipFirst,
                           append: skipFirst > 0,
                           keepPartialOnCancel: isResumable,
                           layout: options.layout,
                           collision: options.collision)
    }
}

extension UnifiedExportFormat {
    var displayName: String {
        switch self {
        case .word: return "Word document"
        case .csv: return "CSV spreadsheet"
        case .json: return "JSON archive"
        case .printText: return "Batch print text"
        case .markdown: return "Markdown"
        case .headersCSV: return "Headers-only CSV"
        case .mbox: return "mbox archive"
        case .emlFiles: return ".eml files"
        case .pdfFiles: return "PDF files"
        case .tiffFiles: return "TIFF images"
        case .msgFiles: return "Outlook .msg files"
        case .portableHTML: return "Portable HTML viewer"
        case .vcard: return "Contacts (vCard)"
        case .ics: return "Calendar events (.ics)"
        }
    }

    var writesFolder: Bool {
        switch self {
        case .emlFiles, .pdfFiles, .tiffFiles, .msgFiles, .portableHTML: return true
        default: return false
        }
    }

    /// Output bytes per stored raw byte — a planning factor, labelled as such
    /// in the sheet. TIFF renders pages as images; CSV keeps a few columns.
    var sizeFactor: Double {
        switch self {
        case .emlFiles, .mbox: return 1.02
        case .msgFiles, .json, .portableHTML: return 1.1
        case .pdfFiles: return 0.8
        case .tiffFiles: return 3.0
        case .word, .markdown, .printText: return 0.35
        case .csv: return 0.06
        case .headersCSV: return 0.01
        case .vcard, .ics: return 0.002
        }
    }
}

