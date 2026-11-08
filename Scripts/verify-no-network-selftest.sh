#!/bin/bash
#
# verify-no-network-selftest.sh — proves verify-no-network.sh judges the
# entitlement VALUES, not their presence (audit F17, 2026-09-28).
#
# Runs the real script against a fake .app with mocked `codesign`, `plutil`,
# `otool`, `nm` and `strings`, for each entitlement shape, and asserts the
# exit code. No real app, signing or network is involved.
#
# Usage: Scripts/verify-no-network-selftest.sh      (exit 0 = all shapes judged correctly)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/verify-no-network.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/mock" "$WORK/Fake.app/Contents/MacOS"
printf 'binary' > "$WORK/Fake.app/Contents/MacOS/Fake"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test</string></dict></plist>\n' \
    > "$WORK/Fake.app/Contents/Info.plist"
# IOS-02: an iOS bundle — executable and Info.plist at the bundle root.
mkdir -p "$WORK/FakeIOS.app"
printf 'binary' > "$WORK/FakeIOS.app/FakeIOS"
cp "$WORK/Fake.app/Contents/Info.plist" "$WORK/FakeIOS.app/Info.plist"

# Mocks. `codesign -d --entitlements` prints $ENT; `codesign --verify` succeeds.
cat > "$WORK/mock/codesign" <<'EOF'
#!/bin/sh
case "$*" in
  *entitlements*) cat "$ENT_FILE" ;;
  *) echo "valid on disk" ;;
esac
EOF
# `plutil -convert xml1 -o - -` passes the entitlements through; `plutil
# -extract NSAppTransportSecurity` reports "no such key" (exit 1).
cat > "$WORK/mock/plutil" <<'EOF'
#!/bin/sh
case "$*" in
  *-extract*) exit 1 ;;
  *) cat ;;
esac
EOF
printf '#!/bin/sh\necho "${MARKER:-mailin.offline.attested}"\n' > "$WORK/mock/strings"
printf '#!/bin/sh\nexit 0\n' > "$WORK/mock/otool"
printf '#!/bin/sh\nexit 0\n' > "$WORK/mock/nm"
chmod +x "$WORK"/mock/*

plist() {   # $1 = dict body, laid out one element per line like `plutil -convert xml1`
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
    printf '%s' "$1" | sed 's|<key>|\n\t<key>|g; s|</key>|</key>\n\t|g' | sed '/^$/d'
    printf '\n</dict>\n</plist>\n'
}

FAILS=0
expect() {  # $1 = shape name, $2 = expected exit (0/1), $3 = dict body, $4 = app (default Fake.app), $5 = marker
    local name="$1" want="$2" app="${4:-Fake.app}"
    if [ -n "$3" ]; then plist "$3" > "$WORK/ent.plist"; else : > "$WORK/ent.plist"; fi
    MARKER="${5:-mailin.offline.attested}" ENT_FILE="$WORK/ent.plist" PATH="$WORK/mock:$PATH" bash "$SCRIPT" "$WORK/$app" > "$WORK/out.txt" 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-42s exit %s\n' "$name" "$got"
    else
        printf '  FAIL  %-42s exit %s, expected %s\n' "$name" "$got" "$want"
        sed 's/^/        /' "$WORK/out.txt" | head -12
        FAILS=$((FAILS + 1))
    fi
}

SANDBOX_KEY='<key>com.apple.security.app-sandbox</key>'
CLIENT_KEY='<key>com.apple.security.network.client</key>'
SERVER_KEY='<key>com.apple.security.network.server</key>'

echo "verify-no-network.sh self-test"
expect "sandbox true, no network keys"        0 "${SANDBOX_KEY}<true/>"
expect "sandbox true, network keys false"     0 "${SANDBOX_KEY}<true/>${CLIENT_KEY}<false/>${SERVER_KEY}<false/>"
expect "sandbox FALSE (key present)"          1 "${SANDBOX_KEY}<false/>"
expect "sandbox key missing"                  1 "<key>com.apple.security.files.user-selected.read-write</key><true/>"
expect "sandbox true, network.client granted" 1 "${SANDBOX_KEY}<true/>${CLIENT_KEY}<true/>"
expect "sandbox true, network.server granted" 1 "${SANDBOX_KEY}<true/>${SERVER_KEY}<true/>"
# IOS-02: iOS bundles carry no app-sandbox entitlement; the marker decides.
expect "iOS: no sandbox key, marker present"  0 "<key>application-identifier</key><string>x</string>" FakeIOS.app
expect "iOS: no entitlements (unsigned sim)"  0 "" FakeIOS.app
expect "iOS: marker missing"                  1 "" FakeIOS.app "mailin.online.capable"
expect "iOS: network.client granted"          1 "${CLIENT_KEY}<true/>" FakeIOS.app
expect "macOS: marker missing"                1 "${SANDBOX_KEY}<true/>" Fake.app "mailin.online.capable"

if [ "$FAILS" -eq 0 ]; then echo "all shapes judged correctly"; exit 0; fi
echo "$FAILS shape(s) misjudged"; exit 1
