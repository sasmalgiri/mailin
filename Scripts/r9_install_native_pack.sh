#!/bin/zsh
# R9 (native mail half): copy the Apple Mail run's output into the fixture pack.
#   Scripts/r9_install_native_pack.sh [<work dir>] [<fixture root>]
# <work>/source/R9-native.mbox + source-inventory.json  (Scripts/r9_make_native_source.py)
# <work>/mail-export/Import/R9-native.mbox/              (Mail: Mailbox > Export Mailbox...)
# <work>/mail-eml/NN.eml + mail-readback.tsv             (Scripts/r9_mail_save_sources.applescript)
set -euo pipefail
WORK=${1:-/tmp/r9-native}
ROOT=${2:-$HOME/Downloads/Mail/Fixtures}
OUT="$ROOT/owner-pack/native"
rm -rf "$OUT"; mkdir -p "$OUT/apple-mail-export" "$OUT/eml" "$OUT/source"
cp -R "$WORK/mail-export/Import/R9-native.mbox" "$OUT/apple-mail-export/"
cp "$WORK/mail-eml/mail-readback.tsv" "$OUT/apple-mail-export/"
cp "$WORK/source/R9-native.mbox" "$WORK/source-inventory.json" "$OUT/source/"
for f in "$WORK"/mail-eml/*.eml; do
  num=$(grep -m1 -o 'r9-native-[0-9][0-9]@' "$f" | cut -c11-12)
  cp "$f" "$OUT/eml/r9-native-$num.eml"
done
xattr -cr "$ROOT/owner-pack" 2>/dev/null || true
ls -R "$OUT"
