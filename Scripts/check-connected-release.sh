#!/bin/bash
#
# check-connected-release.sh — plan v4 T47 for the CONNECTED Release build
# (configuration Release-Connected, MAILIN_CONNECTED_MAIL). The offline Release
# is checked by Scripts/verify-no-network.sh instead.
#
# Checks the built, signed app (not the source):
#   1. the binary is the connected edition (marker mailin.online.capable);
#   2. macOS: network.client granted, network.server not granted, sandbox on;
#   3. Info.plist carries real OAuth values (V4-14, docs/V4_PROVIDER_REGISTRATION.md):
#        MailinGmailClientID     <digits>-<id>.apps.googleusercontent.com
#        MailinGraphClientID     a GUID, not all zeros
#        MailinGraphRedirectURI  msauth.<CFBundleIdentifier>://auth
#      and none is a placeholder (YOUR_…, $(…), empty);
#   4. no cloud-AI code (CloudAIManager) is linked;
#   5. the Gmail sign-in mode (V4-16, MailinGmailSignInMode) is reported:
#        imap   Gmail over IMAP with a Google app password — the 4.0 App Store
#               value in Info-Connected.plist (also when the key is missing);
#        oauth  Google sign-in (Gmail API) — TestFlight / demo builds set it,
#               and 4.0.x once Google has verified the restricted scopes.
#      Either value PASSes (the mode is printed); any other value FAILs.
# The same Info.plist rules run in the app test
# V414ClaimsTests.testT47_thisConnectedReleaseBuildHasRealClientIDs.
#
# Usage: Scripts/check-connected-release.sh /path/to/mailin.app
# Exit 0 = every check passed; 1 = a check failed; 2 = no app.

set -u
APP="${1:-}"
FAILURES=0
pass() { printf '\033[32m  PASS  %s\033[0m\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); printf '\033[31m  FAIL  %s\033[0m\n' "$1"; }

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "Usage: Scripts/check-connected-release.sh /path/to/mailin.app"; exit 2
fi

NAME="$(basename "$APP" .app)"
if [ -f "$APP/Contents/Info.plist" ]; then
    PLIST="$APP/Contents/Info.plist"; BINARY="$APP/Contents/MacOS/$NAME"; PLATFORM=macOS
else
    PLIST="$APP/Info.plist"; BINARY="$APP/$NAME"; PLATFORM=iOS
fi
FILES="$BINARY"; [ -f "$BINARY.debug.dylib" ] && FILES="$BINARY $BINARY.debug.dylib"
echo "Checking $APP ($PLATFORM)"

echo "1. Edition"
# shellcheck disable=SC2086
if strings $FILES 2>/dev/null | grep -q 'mailin.online.capable'; then
    pass "connected edition (mailin.online.capable)"
else
    fail "not the connected edition (no mailin.online.capable marker) — use Scripts/verify-no-network.sh for the offline build"
fi

echo "2. Entitlements"
if [ "$PLATFORM" = macOS ]; then
    ENT=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null | tr -d '\n\r\t ')
    value() { printf '%s' "$ENT" | sed -n "s|.*<key>$1</key><\([a-z]*\)/>.*|\1|p" | head -1; }
    [ "$(value com.apple.security.app-sandbox)" = true ] && pass "sandbox on" || fail "sandbox not on"
    [ "$(value com.apple.security.network.client)" = true ] && pass "network.client granted (mail only)" || fail "network.client not granted — connected mail cannot work"
    [ "$(value com.apple.security.network.server)" = true ] && fail "network.server granted (never needed)" || pass "network.server not granted"
else
    echo "  NOTE  iOS: no network entitlement exists; nothing to check here."
fi

echo "3. OAuth client values in Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }
placeholder() { printf '%s' "$1" | grep -qiE 'your|placeholder|client_id|clientid|example|xxxx|todo|changeme|replace|dummy|<|>|\{|\}|\$\('; }
BUNDLE=$(read_key CFBundleIdentifier)
GMAIL=$(read_key MailinGmailClientID)
GRAPH=$(read_key MailinGraphClientID)
REDIRECT=$(read_key MailinGraphRedirectURI)

if [ -z "$GMAIL" ]; then fail "MailinGmailClientID missing or empty"
elif placeholder "$GMAIL"; then fail "MailinGmailClientID is a placeholder ($GMAIL)"
elif printf '%s' "$GMAIL" | grep -qE '^[0-9]{6,}-[a-z0-9]{16,}\.apps\.googleusercontent\.com$'; then pass "MailinGmailClientID is a native Google client ID"
else fail "MailinGmailClientID is not <digits>-<id>.apps.googleusercontent.com ($GMAIL)"; fi

if [ -z "$GRAPH" ]; then fail "MailinGraphClientID missing or empty"
elif placeholder "$GRAPH" || [ "$GRAPH" = "00000000-0000-0000-0000-000000000000" ]; then fail "MailinGraphClientID is a placeholder ($GRAPH)"
elif printf '%s' "$GRAPH" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then pass "MailinGraphClientID is a GUID"
else fail "MailinGraphClientID is not a GUID ($GRAPH)"; fi

EXPECTED="msauth.$BUNDLE://auth"
if [ -z "$REDIRECT" ]; then fail "MailinGraphRedirectURI missing or empty"
elif [ "$(printf '%s' "$REDIRECT" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$EXPECTED" | tr 'A-Z' 'a-z')" ]; then pass "MailinGraphRedirectURI = $EXPECTED"
else fail "MailinGraphRedirectURI is $REDIRECT, expected $EXPECTED"; fi

echo "4. No cloud AI linked"
# shellcheck disable=SC2086
N=$( (nm $FILES 2>/dev/null || true) | grep -c CloudAIManager)
[ "$N" = 0 ] && pass "no CloudAIManager symbol" || fail "$N CloudAIManager symbols — MAILIN_CLOUD_AI must not be defined"

echo "5. Gmail sign-in mode"
MODE_RAW=$(read_key MailinGmailSignInMode)
MODE=$(printf '%s' "$MODE_RAW" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
case "$MODE" in
    imap)  pass "MailinGmailSignInMode = imap (Gmail over IMAP with an app password; the 4.0 App Store mode)" ;;
    oauth) pass "MailinGmailSignInMode = oauth (Google sign-in; TestFlight / demo / 4.0.x mode)" ;;
    "")    pass "MailinGmailSignInMode missing: the app reads it as imap (Gmail over IMAP with an app password)" ;;
    *)     fail "MailinGmailSignInMode is '$MODE_RAW', expected imap or oauth" ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then echo "T47 connected checks: PASS"; exit 0; fi
echo "T47 connected checks: $FAILURES FAILED"; exit 1
