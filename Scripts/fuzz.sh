#!/bin/zsh
# §3-P3: coverage-guided fuzzing of ArchiveCore's parsers (see Fuzz/README.md).
# Needs the swift.org toolchain for macOS (Apple's Xcode toolchain has no libFuzzer on macOS).
set -e
cd "$(dirname "$0")/.."
TOOLCHAIN="${SWIFT_TOOLCHAIN:-$(ls -d /Library/Developer/Toolchains/swift-*.xctoolchain 2>/dev/null | tail -1)}"
if [[ -z "$TOOLCHAIN" ]]; then
  echo "No swift.org toolchain found in /Library/Developer/Toolchains. Install one, or set SWIFT_TOOLCHAIN." >&2
  exit 2
fi
SWIFT="$TOOLCHAIN/usr/bin/swift"
SECONDS_TO_RUN="${FUZZ_SECONDS:-1800}"

mkdir -p Fuzz/Corpus Fuzz/Findings
# Seed corpus: the bundled demo mailbox and the test fixtures, one message per file.
if [[ -z "$(ls -A Fuzz/Corpus)" ]]; then
  awk 'BEGIN{n=0} /^From /{n++} {print > ("Fuzz/Corpus/seed-" n ".eml")}' maxmailin/demo_emails.mbox
fi

(cd Fuzz && "$SWIFT" build -c debug)
Fuzz/.build/debug/ArchiveCoreFuzz Fuzz/Corpus \
  -max_total_time="$SECONDS_TO_RUN" -timeout=20 -rss_limit_mb=4096 \
  -artifact_prefix=Fuzz/Findings/
