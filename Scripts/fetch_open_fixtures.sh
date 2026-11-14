#!/bin/zsh
# Downloads public test mail used by the opt-in real-data tests (not shipped,
# not committed): Digital Corpora "filetypes1" PST and Thunderbird samples
# (free to use, https://digitalcorpora.org/about-digitalcorpora/).
set -e
DEST="${1:-$HOME/Downloads/Mail/Fixtures/digitalcorpora}"
mkdir -p "$DEST"; cd "$DEST"
for f in PST Tbird; do
  [ -f "$f.zip" ] || curl -sSfO "https://digitalcorpora.s3.amazonaws.com/corpora/files/filetypes1/$f.zip"
  [ -d "$f" ] || unzip -q "$f.zip" -d "$f"
done
echo "Fixtures in $DEST — run: MAILIN_REAL_FIXTURES=$DEST xcrun swift test --package-path Packages/ArchiveCore --filter RealDataRecoveryTests"
