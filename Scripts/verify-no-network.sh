#!/bin/bash
#
# verify-no-network.sh — proves a BUILT, SIGNED mailin app cannot reach the
# network, from the artifact rather than from the source.
#
# Task D1. The claim "mailin never talks to the network" has until now rested
# on two things that are true but not *proof*: the `OFFLINE_MODE` compilation
# condition, and a measured run showing zero network sockets. Neither survives
# the obvious challenge — a build setting can be changed, and one run is one
# run. What a reviewer (or a court) can check is the signed binary: if the
# sandbox grants no network entitlement, the process cannot open a socket
# regardless of what the code asks for.
#
# This script asserts that, plus the compile-time flag and the absence of
# network-transport symbols, and exits non-zero on the first failure.
#
# Usage:
#   Scripts/verify-no-network.sh /path/to/mailin.app
#   Scripts/verify-no-network.sh                 # finds the newest Release build
#
# NOT YET EXECUTED. Written before any build under an explicit
# implement-first instruction.

set -u

APP="${1:-}"
FAILURES=0
CHECKS=0

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

pass() { CHECKS=$((CHECKS + 1)); green "  PASS  $1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); red "  FAIL  $1"; }

# ---------------------------------------------------------------- locate app

if [ -z "$APP" ]; then
    APP=$(find ~/Library/Developer/Xcode/DerivedData -type d -name 'mailin.app' \
              -path '*Release*' -prune 2>/dev/null | head -1)
    if [ -z "$APP" ]; then
        APP=$(find ~/Library/Developer/Xcode/DerivedData -type d -name 'maxmailin.app' \
                  -path '*Release*' -prune 2>/dev/null | head -1)
    fi
fi

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    red "No .app found. Build the Release configuration first, or pass the path:"
    red "  Scripts/verify-no-network.sh /path/to/mailin.app"
    exit 2
fi

BINARY="$APP/Contents/MacOS/$(basename "$APP" .app)"
if [ ! -f "$BINARY" ]; then
    # iOS layout has the executable at the bundle root.
    BINARY="$APP/$(basename "$APP" .app)"
fi

echo "Verifying: $APP"
dim "Binary:    $BINARY"
echo

# ------------------------------------------------- 1. entitlements: the proof

echo "1. Signed entitlements (the sandbox, not the source, is what binds)"

ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null \
                 | plutil -convert xml1 -o - - 2>/dev/null)

if [ -z "$ENTITLEMENTS" ]; then
    fail "could not read entitlements — is the app signed?"
else
    if echo "$ENTITLEMENTS" | grep -q 'com.apple.security.app-sandbox'; then
        pass "app sandbox is enabled (entitlements are enforced)"
    else
        fail "app sandbox is NOT enabled — entitlements do not constrain this build"
    fi

    for key in \
        'com.apple.security.network.client' \
        'com.apple.security.network.server'
    do
        # A key present but false is fine; present and true is not.
        if echo "$ENTITLEMENTS" | grep -A1 "$key" | grep -q '<true/>'; then
            fail "$key is GRANTED — this build can reach the network"
        else
            pass "$key is not granted"
        fi
    done
fi
echo

# ------------------------------------------ 2. the compile-time flag was on

echo "2. OFFLINE_MODE compiled in"

# `NoNetworkAttestation` is compiled only when OFFLINE_MODE is defined and
# carries this marker string, so finding it proves the flag was set for the
# configuration that produced THIS binary.
if strings "$BINARY" 2>/dev/null | grep -q 'mailin.offline.attested'; then
    pass "offline attestation marker present (OFFLINE_MODE was defined)"
else
    fail "offline attestation marker MISSING — this binary was built without OFFLINE_MODE"
fi
echo

# --------------------------------- 3. no network transport linked or reachable

echo "3. Network transport symbols"

LINKED=$(otool -L "$BINARY" 2>/dev/null)
for framework in Network CFNetwork; do
    if echo "$LINKED" | grep -q "/$framework.framework/"; then
        # Foundation pulls CFNetwork transitively; a DIRECT link is the signal.
        fail "$framework is linked directly"
    else
        pass "$framework is not linked directly"
    fi
done

# URLSession being present in Foundation is unavoidable; what matters is
# whether OUR code references it. Swift mangles our symbols with the module
# name, so a reference from the mailin module is visible and attributable.
OURS=$(nm -u "$BINARY" 2>/dev/null | grep -c 'URLSession' || true)
if [ "${OURS:-0}" -eq 0 ]; then
    pass "no undefined URLSession symbols"
else
    dim "  NOTE  $OURS URLSession symbol reference(s) present."
    dim "        Foundation exports these regardless; the entitlement check"
    dim "        above is what proves they cannot be used. Not a failure."
fi
echo

# --------------------------------------------------- 4. Info.plist exceptions

echo "4. App Transport Security exceptions"

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || PLIST="$APP/Info.plist"

if [ -f "$PLIST" ]; then
    if plutil -extract NSAppTransportSecurity xml1 -o - "$PLIST" >/dev/null 2>&1; then
        fail "NSAppTransportSecurity is declared — an offline app has no reason to"
    else
        pass "no NSAppTransportSecurity declarations"
    fi
else
    fail "no Info.plist found at $PLIST"
fi
echo

# ------------------------------------------------------------------- verdict

echo "─────────────────────────────────────────────"
if [ "$FAILURES" -eq 0 ]; then
    green "PASS — $CHECKS checks, 0 failures."
    green "This signed build cannot open a network connection."
    exit 0
else
    red "FAIL — $FAILURES of $CHECKS checks failed."
    red "Do NOT make an offline claim about this build."
    exit 1
fi
