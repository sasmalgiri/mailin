# ArchiveCore coverage-guided fuzzing (SCALE_TODO_3_0.md §3-P3)

The property-based part of P3 runs in every test pass (`maxmailinTests/V3ParserFuzzTests.swift`). This package
is the coverage-guided part: libFuzzer mutates inputs by the code paths they reach in the parsers, with
AddressSanitizer on.

## Why it is separate

Apple's Xcode toolchain rejects `-sanitize=fuzzer` on macOS
(`unsupported option '-sanitize=fuzzer' for target 'arm64-apple-macosx'`, checked 2026-10-11). The swift.org
toolchain for macOS ships libFuzzer. Linux is not an option: ArchiveCore uses Apple frameworks (Compression,
CryptoKit, NaturalLanguage).

## Run

1. Install the swift.org toolchain for macOS (owner decision: it is a download).
2. `Scripts/fuzz.sh` builds this package with that toolchain and runs the harness for 30 minutes. The seed corpus
   is `Fuzz/Corpus`, built from the fixture mail. The run stops at the first crash, hang (20 s) or sanitizer report.
3. A finding is saved as `Fuzz/Findings/crash-<sha1>`. Reproduce it with
   `.build/debug/ArchiveCoreFuzz Fuzz/Findings/crash-<sha1>`, then add it to
   `V3ParserFuzzTests` as a fixed regression case.

## What the harness covers

Each input goes through:

- `MIMEParser.parseEmail` directly;
- `ParserFactory.parseStreamingCallback` as a file under one of mbox, eml, emlx, msg, pst, nsf or zip, chosen by
  the input's first byte. Format sniffing, container handling and every binary parser are reached.
