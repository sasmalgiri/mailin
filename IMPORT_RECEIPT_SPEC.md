# Import receipt specification (3.0 A5)

The receipt is the answer to "did that import actually get everything?". One is written for every
run, signed, and shown in the app (banner, File ▸ Last Import Receipt…, import queue verdict). This
document is the contract for its fields; the code is `ImportReceipt.swift` and `ImportReconciler`.

## 1. Fields (schema version 3)

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | Int | 3 |
| `sources[]` | `SourceRecord` | per file: `filename`, `sizeBytes`, `sha256`, `parser`, `parserVersion` — the engine that actually ran |
| `discovered` | Int | message envelopes found in the sources |
| `parsed` | Int | messages the parser produced |
| `inserted` | Int? | rows the store committed (nil when the store did not report) |
| `duplicates` | Int? | rows withheld by the dedup policy |
| `damaged` | Int | messages the parser rejected (oversized, malformed) |
| `skipped` | Int | files skipped because their SHA-256 was already fully imported |
| `persistFailed` | Int | messages whose store insert failed (hard error, counted per file) |
| `indexed` | Int | rows the FTS index accepted this run |
| `bodiesNotDecoded` | Int | messages archived from their headers and locator only (offset engine, above the full-parse ceiling) |
| `attachmentsSeen` | Int | attachment parts across committed messages |
| `fileFailures[]` | `FileFailure` | per file that could not be imported: `filename`, `message` |
| `warnings[]` | String | free-tier cap, user stops, resume notes |
| `startedAt`, `completedAt`, `durationSeconds` | Date/Double | wall clock |
| `resumed`, `resumedDetail` | Bool/String? | whether a checkpoint was used and where |
| `ftsDegraded`, `ftsFailedBatchCount` | Bool/Int | FTS commits that failed; the launch reconciler repairs them |
| `reconciliationPending` | Bool | true when store↔FTS drift exists at receipt time |
| `storeCountBefore`, `storeCountAfter`, `ftsRowCount` | Int? | the counts the verdict is computed from |
| `contentHash` | String | SHA-256 of the receipt body (everything above) |
| `signature`, `signingKeyID` | String | HMAC over `contentHash` with a per-install Keychain key (`ReceiptSigner`) |

## 2. Identities the verdict checks (`ImportReconciler`)

1. `discovered == parsed + damaged`
2. `storeCountAfter − storeCountBefore == inserted` (when both known)
3. `parsed − persistFailed − duplicates == inserted` (when known)
4. `ftsRowCount == storeCountAfter` unless `ftsDegraded` (then `reconciliationPending`)

| Verdict | When |
|---|---|
| **Complete** | every identity holds, no file failures, no cap, not stopped |
| **Partial** | cap reached, a file stopped by the user, damaged > 0, or `reconciliationPending` |
| **Failed** | a file failure, `persistFailed > 0`, or an identity broken |

The queue and the receipt compute the verdict from the same reconciliation, so they cannot disagree.

## 3. Storage and reach

- JSON under `<Application Support>/mailin/import-receipts/receipt-<epoch>-<id>.json`, protected
  class *complete until first user authentication*, owner-only permissions (`ArtifactProtection`).
- Verified on read: `verify()` recomputes `contentHash` and the HMAC; a tampered receipt reads as
  such in the UI.
- Reachable from: the post-import banner, File ▸ Last Import Receipt…, the queue row's verdict, and
  Retry (by file name via `BulkImportCoordinator.lastRunSourceURLs`).

## 4. Relationship to other receipts

`ExportReceipt` (every export, incl. handoff and production) and `RelocationReceipt` (archive move)
follow the same rule: every run ends in a record that says what was requested, what was written,
the outcome, and the hash — silence is not an outcome.
