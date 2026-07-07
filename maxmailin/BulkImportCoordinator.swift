//
//  BulkImportCoordinator.swift
//  maxmailin
//
//  Coordinates the full import pipeline:
//
//      file → SHA-256 → checkpoint check → ParserFactory.parse →
//             EmailStore.insertBatch → FTSSearchIndex.indexBatch → checkpoint
//
//  Designed for the 1 TB-scale story:
//   • Per-file pipelining — never holds more than one source file's parsed
//     emails in memory at once. (Was previously accumulating across all files.)
//   • Resumable — files whose SHA-256 hash is already recorded in the
//     ImportCheckpointStore are skipped. A crash mid-ingest at 800 GB resumes
//     from the last fully-ingested file instead of restarting at 0.
//   • Batched persistence and indexing — one transaction per batch.
//   • Cooperative cancellation on Task.isCancelled.
//   • Forensic SHA-256 of each source file recorded for chain of custody.
//
//  Pure-Swift, on-device, no network.
//

import Foundation
import CryptoKit
import SwiftUI

@MainActor
@Observable
final class BulkImportCoordinator {

    enum Status: Equatable {
        case idle
        case hashing(file: String)
        case parsing(file: String)
        case persisting(processed: Int, total: Int)
        case indexing(processed: Int, total: Int)
        case completed(count: Int, skipped: Int)
        case failed(String)
        case cancelled
    }

    var status: Status = .idle
    var lastFinishedAt: Date?
    private var task: Task<Void, Never>?

    /// Import one or more archive files into the SwiftData store and FTS5
    /// search index. Each file is hashed first; files whose hash already
    /// appears in the ImportCheckpointStore are skipped so that resuming after
    /// a crash (or re-dropping the same archive) does not re-do work.
    func startImport(urls: [URL], batchSize: Int = 500) {
        cancel()
        // Clamp batchSize to a sane range. Values <= 0 would divide-by-zero
        // in chunked Array operations downstream; absurdly large values
        // defeat the streaming-pipeline memory bound.
        let safeBatchSize = max(1, min(batchSize, 10_000))
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(urls: urls, batchSize: safeBatchSize)
            } catch is CancellationError {
                await MainActor.run { self.status = .cancelled }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Cooperative cancellation. Safe to call at any point.
    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Pipeline

    private func run(urls: [URL], batchSize: Int) async throws {
        var totalImported = 0
        var totalSkipped = 0

        for url in urls {
            try Task.checkCancellation()

            // 1. Hash this file for chain of custody + checkpoint lookup.
            await MainActor.run { self.status = .hashing(file: url.lastPathComponent) }
            let hash = try await Self.sha256(of: url)

            // 2. Skip if we have already fully ingested this file.
            if await ImportCheckpointStore.shared.isImported(sha256: hash) {
                totalSkipped += 1
                continue
            }

            try Task.checkCancellation()

            // 3. Parse + persist + index this file as a true streaming
            //    pipeline. Each batch of `batchSize` parsed messages is
            //    persisted and indexed, then dropped — so peak memory is
            //    bounded by `batchSize`, regardless of source file size.
            //    Mbox files >50 GB (Gmail Takeout etc.) ingest without
            //    holding the file in RAM.
            //
            //    Resumability: if this file was partially imported in an
            //    earlier session that crashed, `batchesAlreadyDone` is
            //    non-zero. We re-parse those leading batches but skip
            //    persist + index — turning what would be a 200 GB redo
            //    into a parse-and-discard pass (typically minutes vs
            //    hours).
            await MainActor.run { self.status = .parsing(file: url.lastPathComponent) }
            let baseline = totalImported
            var fileCount = 0
            let batchesAlreadyDone = await ImportCheckpointStore.shared
                .batchesIngested(sha256: hash)
            var batchIndex = 0
            let sourceName = url.lastPathComponent

            do {
                let parsedCount = try await ParserFactory.parseStreamingCallback(
                    fileURL: url,
                    senderEmail: "",
                    batchSize: batchSize,
                    onProgress: nil
                ) { [weak self] batch in
                    guard let self else { return }
                    try Task.checkCancellation()

                    // Skip batches that were already persisted + indexed in
                    // a prior crashed session.
                    let thisBatch = batchIndex
                    batchIndex += 1
                    if thisBatch < batchesAlreadyDone {
                        return
                    }

                    let processedBefore = baseline + fileCount
                    await MainActor.run {
                        self.status = .persisting(
                            processed: processedBefore,
                            total: processedBefore + batch.count
                        )
                    }
                    try await EmailStore.shared.insertBatch(
                        batch,
                        sourceFileHash: hash,
                        batchSize: batchSize,
                        progress: nil
                    )
                    try Task.checkCancellation()
                    await MainActor.run {
                        self.status = .indexing(
                            processed: processedBefore,
                            total: processedBefore + batch.count
                        )
                    }
                    try await FTSSearchIndex.shared.indexBatch(batch)
                    fileCount += batch.count

                    // Per-batch checkpoint AFTER both persist + index
                    // succeed. A crash now resumes from the next batch
                    // rather than redoing the whole file.
                    await ImportCheckpointStore.shared.recordBatch(
                        sha256: hash,
                        sourceName: sourceName,
                        batchesIngested: thisBatch + 1
                    )
                    // batch falls out of scope here — its storage is released
                    // before the next batch begins.
                }
                _ = parsedCount
            } catch is CancellationError {
                throw CancellationError()
            }

            // 4. Record file-complete checkpoint AFTER every batch in this
            //    file has been persisted + indexed. This clears the
            //    in-progress per-batch checkpoint so future runs see it
            //    as fully done. Empty files still get a checkpoint so we
            //    don't re-hash them next run. emailCount approximates the
            //    total across all sessions (this session + any prior
            //    crashed-and-resumed sessions).
            let priorSessionCount = batchesAlreadyDone * batchSize
            await ImportCheckpointStore.shared.record(
                sha256: hash,
                sourceName: url.lastPathComponent,
                emailCount: fileCount + priorSessionCount
            )

            totalImported += fileCount
        }

        await MainActor.run {
            self.status = .completed(count: totalImported, skipped: totalSkipped)
            self.lastFinishedAt = Date()
        }
    }

    // MARK: - File hashing

    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
