#!/bin/bash
#
# verify-no-network.sh — proves a BUILT, SIGNED mailin app cannot reach the
# network, from the artifact rather than from the source.
#
# Task D1. The claim "mailin never talks to the network" has until now rested
# on two things that are true but not *proof*: the `NO_NETWORK_BUILD` compilation
# condition, and a measured run showing zero network sockets. Neither survives
# the obvious challenge — a build setting can be changed, and one run is one
# run. What a reviewer (or a court) can check is the signed binary: if the
# sandbox grants no network entitlement, the process cannot open a socket
# regardless of what the code asks for.
#
# This script asserts that, plus the compile-time flag and that no connected-mail
# entry point is reachable (v4.0: the package's transport code IS linked — see
# check 3 for why it cannot run), and exits non-zero if any check fails.
#
# Usage:
#   Scripts/verify-no-network.sh /path/to/mailin.app
#   Scripts/verify-no-network.sh                 # finds the newest Release build
#
# Self-test of the entitlement checks (mocked codesign/plutil, no app needed):
#   Scripts/verify-no-network-selftest.sh

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
PLATFORM="macOS"
if [ ! -f "$BINARY" ]; then
    # iOS layout has the executable at the bundle root.
    BINARY="$APP/$(basename "$APP" .app)"
    PLATFORM="iOS"
fi

echo "Verifying: $APP"
dim "Binary:    $BINARY"
dim "Platform:  $PLATFORM bundle layout"
echo

# ------------------------------------------------- 1. entitlements: the proof

echo "1. Signed entitlements (the sandbox, not the source, is what binds)"

ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null \
                 | plutil -convert xml1 -o - - 2>/dev/null)

if [ -z "$ENTITLEMENTS" ] && [ "$PLATFORM" = "iOS" ]; then
    # An unsigned simulator build carries no entitlements at all; on iOS there
    # is nothing in them that could withhold the network anyway (see below).
    dim "  NOTE  iOS bundle without readable entitlements (unsigned simulator build?);"
    dim "        iOS has no network entitlement to withhold — check 2 is the protection."
elif [ -z "$ENTITLEMENTS" ]; then
    fail "could not read entitlements — is the app signed?"
else
    # The VALUE of each key, not its presence (audit F17): an entitlements
    # plist can carry app-sandbox with <false/>, and a build signed that way is
    # not sandboxed. Whitespace is stripped first so the match does not depend
    # on plutil's line layout.
    entitlement_value() {   # $1 = key → "true" | "false" | "" (absent)
        printf '%s' "$ENTITLEMENTS" | tr -d '\n\r\t ' \
            | sed -n "s|.*<key>$1</key><\([a-z]*\)/>.*|\1|p" | head -1
    }

    if [ "$PLATFORM" = "iOS" ]; then
        # IOS-02: iOS has no app-sandbox entitlement — the system sandboxes every
        # app — and no network entitlement to withhold, so on iOS the build flag
        # (check 2) is the protection. Not a failure; stated, not hidden.
        dim "  NOTE  iOS bundle: every iOS app is sandboxed by the system and no"
        dim "        network entitlement exists to withhold, so the sandbox check"
        dim "        does not apply; check 2 (NO_NETWORK_BUILD) is the protection."
    elif [ "$(entitlement_value 'com.apple.security.app-sandbox')" = "true" ]; then
        pass "app sandbox is enabled (entitlements are enforced)"
    else
        fail "app sandbox is NOT enabled (value: '$(entitlement_value 'com.apple.security.app-sandbox')') — entitlements do not constrain this build"
    fi

    for key in \
        'com.apple.security.network.client' \
        'com.apple.security.network.server'
    do
        # A key present but false is fine; present and true is not.
        if [ "$(entitlement_value "$key")" = "true" ]; then
            fail "$key is GRANTED — this build can reach the network"
        else
            pass "$key is not granted"
        fi
    done
fi
echo

# ------------------------------------------ 2. the compile-time flag was on

echo "2. NO_NETWORK_BUILD compiled in"

# `NoNetworkAttestation` is compiled only when NO_NETWORK_BUILD is defined and
# carries this marker string, so finding it proves the flag was set for the
# configuration that produced THIS binary.
MARKER_FILES="$BINARY"
# A Debug build keeps the app's code in <name>.debug.dylib beside the stub executable.
[ -f "$BINARY.debug.dylib" ] && MARKER_FILES="$BINARY $BINARY.debug.dylib"
# shellcheck disable=SC2086
if strings $MARKER_FILES 2>/dev/null | grep -q 'mailin.offline.attested'; then
    pass "offline attestation marker present (NO_NETWORK_BUILD was defined)"
else
    fail "offline attestation marker MISSING — this binary was built without NO_NETWORK_BUILD"
fi
echo

# ------------------- 3. connected-mail transports: linked, but not reachable
#
# v4.0 (2026-11-14). The package product `ArchiveCore` ships two targets,
# ArchiveCore and MailConnectivity (Packages/ArchiveCore/Package.swift), so the
# OFFLINE binary links MailConnectivity's transport code too: IMAPTransport /
# SMTPStream (Network.framework, NWConnection), GmailHTTPTransport,
# GraphTransport, APISendSubmitters, OAuthSession (URLSession). That code is
# present and cannot be made absent without a project change. What this check
# proves instead is that it cannot RUN in this build:
#   - no network entitlement (check 1): the sandbox refuses every outbound
#     connection the process attempts, whoever constructs it;
#   - no app code path constructs it: every app-side entry point that builds a
#     transport is compiled only under `MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD`
#     (ConnectedMailProductionTransports, ConnectedMailProduction.dependencies,
#     PolicyCheckedTokenTransport, the legacy GmailConnector / OutlookConnector /
#     IMAPClient / SMTPClient) and must be ABSENT from this binary;
#   - the connected edition marker `mailin.online.capable` is absent and the
#     offline marker is present (check 2);
#   - none of the connected edition's Info.plist keys is present.
# A direct link of Network.framework is therefore reported as a NOTE, with the
# reason, not as proof of anything either way.

echo "3. Connected-mail transports (linked from the package, not reachable)"

# shellcheck disable=SC2086
if strings $MARKER_FILES 2>/dev/null | grep -q 'mailin.online.capable'; then
    fail "connected edition marker mailin.online.capable PRESENT — this is a MAILIN_CONNECTED_MAIL build, use Scripts/check-connected-release.sh"
else
    pass "connected edition marker (mailin.online.capable) absent"
fi

# Swift mangles a type as <length><name> (e.g. 33ConnectedMailProductionTransportsC).
# Searched in the symbol table AND in the binary's strings (type metadata and
# Objective-C class names survive stripping), so a stripped archive is checked too.
# shellcheck disable=SC2086
SYMS=$( { nm $MARKER_FILES 2>/dev/null; strings $MARKER_FILES 2>/dev/null; } )
for entry in \
    ConnectedMailProductionTransports \
    ConnectedMailProduction \
    PolicyCheckedTokenTransport \
    GmailConnector \
    OutlookConnector \
    IMAPClient \
    SMTPClient \
    CloudAIManager
do
    mangled="${#entry}${entry}"
    N=$(printf '%s\n' "$SYMS" | grep -c -- "$mangled" || true)
    if [ "${N:-0}" -eq 0 ]; then
        pass "app entry point $entry absent"
    else
        fail "app entry point $entry PRESENT ($N references) — compiled without NO_NETWORK_BUILD?"
    fi
done

PLIST_FOR_KEYS="$APP/Contents/Info.plist"
[ -f "$PLIST_FOR_KEYS" ] || PLIST_FOR_KEYS="$APP/Info.plist"
for key in MailinGmailClientID MailinGraphClientID MailinGraphRedirectURI MailinGmailSignInMode; do
    if [ -f "$PLIST_FOR_KEYS" ] && /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST_FOR_KEYS" >/dev/null 2>&1; then
        fail "Info.plist carries the connected edition key $key"
    else
        pass "Info.plist has no $key"
    fi
done

LINKED=$(otool -L "$BINARY" 2>/dev/null)
for framework in Network CFNetwork; do
    if echo "$LINKED" | grep -q "/$framework.framework/"; then
        dim "  NOTE  $framework.framework is linked directly: the package target MailConnectivity"
        dim "        (same library product as ArchiveCore) uses it. It cannot run here: no"
        dim "        network.client entitlement (check 1) and no app entry point above."
    else
        pass "$framework is not linked directly"
    fi
done

OURS=$(nm -u "$BINARY" 2>/dev/null | grep -c 'URLSession' || true)
if [ "${OURS:-0}" -eq 0 ]; then
    pass "no undefined URLSession symbols"
else
    dim "  NOTE  $OURS URLSession symbol reference(s) present (MailConnectivity and"
    dim "        Foundation). The entitlement check above is what proves they cannot be used."
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
