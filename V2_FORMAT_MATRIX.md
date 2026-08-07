# V2 FORMAT MATRIX (§7)

Executable truth for every import format, as shipped on `v2-core-cutover`.

| Format | Production parser | Streaming? | Whole-file memory? | Per-message ceiling | File ceiling | Corruption recovery | Resume locator | Test fixture | Public claim |
|--------|------------------|------------|--------------------|--------------------|--------------|--------------------|----------------|--------------|--------------|
| MBOX | `MBOXParser.parseStreamingCallback` | Yes — bounded batch callback | No — 64 KB read chunks, one message resident | 100 MB (`maxMessageBytes`); oversized counted damaged, never OOM | None (streamed) | Per-message: damaged counted + categorized in returned report; I/O read error THROWS (never fake EOF) | message ordinal (checkpoint, identity-bound) | `V2ParserHardeningTests`, coordinator tests | "Bounded-memory import at any size" — supported |
| (no extension) | Treated as MBOX (Google Takeout ships extensionless mbox) | Yes | No | 100 MB | None | Same as MBOX | ordinal | covered by MBOX path | documented mapping |
| EML | MBOX parser, single bounded RFC-822 message ("From " envelope synthesized if absent — a normal `From:`-first .eml parses correctly) | Yes (trivially) | One message | 100 MB | 500 MB array path / streamed | Throws on unreadable | whole file | `V2ParserHardeningTests.testEML_fromHeaderFirst_parsesAsSingleMessage` | supported |
| EMLX | `EMLXParser` | Per-file (Apple Mail stores one message per .emlx) | One message | n/a | n/a | Throws on unreadable | whole file | existing parser tests | supported |
| MSG | `MSGParser` | No (single message) | One message | n/a | n/a | Throws | whole file | existing | supported |
| PST/OST | `PSTParser` (B-tree reader over `.mappedIfSafe` mmap) | Batch emission; mmap pages only touched bytes | mmap (not RSS-resident) | n/a | **50 GB executed-safe cap** (enforced) | Throws with reason | whole file | existing | "PST import up to 50 GB" — do NOT claim arbitrary-size |
| NSF | `NSFParser` (mmap) | Batch emission | mmap | n/a | **64 GB cap** (enforced) | Throws | whole file | existing | "NSF import up to 64 GB" |
| ZIP | **Not supported in v2.0** — explicit `unsupportedFormat` error with guidance (unzip, import members) | — | — | — | — | — | — | `testUnsupportedExtensions_rejectedExplicitly` | Must NOT be claimed. v2.1 backlog: bounded ZIP member extraction |
| other/unknown | Explicit `unsupportedFormat` error (no silent MBOX fallthrough) | — | — | — | — | — | — | same test | — |

## §7.7 Recovery reporting

`ParserFactory.parseStreamingCallback` RETURNS a source-scoped
`ParseRecoveryReport` (discovered/parsed/damaged/error categories). There is
no global mutable report; concurrent imports cannot race. The coordinator
aggregates per-file reports into the run summary and the signed receipt.

## §7.1 I/O errors

A `FileHandle.read` failure mid-parse **throws** (`ExtractionError.invalidEmail`
with the byte offset). It is never treated as EOF, so a failing disk/network
volume cannot silently truncate an archive while reporting success.
