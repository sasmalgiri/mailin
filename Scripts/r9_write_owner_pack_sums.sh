#!/bin/zsh
# R9: (re)write <root>/owner-pack/SHA256SUMS (paths relative to owner-pack/, `shasum -a 256` format),
# plus a per-directory copy in smime/ and native/ for people reading the pack by hand.
set -euo pipefail
ROOT=${1:-$HOME/Downloads/Mail/Fixtures}
cd "$ROOT/owner-pack"
xattr -cr . 2>/dev/null || true
find . -type f ! -name SHA256SUMS ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do shasum -a 256 "$f"; done > SHA256SUMS
for d in smime native; do
  [[ -d $d ]] || continue
  (cd $d && find . -type f ! -name SHA256SUMS ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do shasum -a 256 "$f"; done > SHA256SUMS)
done
wc -l SHA256SUMS
