#!/bin/zsh
#
# testflight.sh — archive, verify and (optionally) upload mailin to
# TestFlight for iOS and macOS in one command.
#
#   Scripts/testflight.sh --build 302                 # archive + verify + export, NO upload
#   Scripts/testflight.sh --build 302 --upload        # ...and upload to App Store Connect
#   Scripts/testflight.sh --build 302 --platform ios  # one platform only (ios | macos | both)
#   Scripts/testflight.sh --build 302 --tests         # run the purchase + gate tests first
#
# The build number is passed to xcodebuild (CURRENT_PROJECT_VERSION), so the
# project file is never edited; App Store Connect requires a new number for
# every upload. Signing is automatic with team 6TPTCJD42Q. Authentication:
# an App Store Connect API key when ASC_KEY_ID, ASC_ISSUER_ID and
# ASC_KEY_PATH are set, otherwise the Apple Account signed in to Xcode.
#
# Each archive is checked before export: bundle id, version and build,
# NO_NETWORK_BUILD, and on macOS the sandbox entitlement and
# Scripts/verify-no-network.sh. Any failure stops the script before upload.

set -u
ROOT="${0:A:h:h}"
cd "$ROOT"

PROJECT=maxmailin.xcodeproj
SCHEME=maxmailin
TEAM=6TPTCJD42Q
BUNDLE_ID=com.ecosanskriti.mailin
XB=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild

BUILD=""
PLATFORM=both
UPLOAD=0
RUN_TESTS=0
while (( $# )); do
    case "$1" in
        --build) BUILD="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --upload) UPLOAD=1; shift ;;
        --tests) RUN_TESTS=1; shift ;;
        -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done
[[ -n "$BUILD" && "$BUILD" == <-> ]] || { echo "--build <integer> is required (higher than any build already uploaded)"; exit 2; }
case "$PLATFORM" in ios|macos|both) ;; *) echo "--platform must be ios, macos or both"; exit 2 ;; esac

OUT="$ROOT/build-testflight/$BUILD"
mkdir -p "$OUT"
LOG="$OUT/testflight.log"
: > "$LOG"
say() { print -r -- "$*" | tee -a "$LOG"; }
fail() { say "FAIL: $*"; exit 1; }

AUTH=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
    AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    say "Auth: App Store Connect API key $ASC_KEY_ID"
else
    say "Auth: the Apple Account signed in to Xcode"
fi

if [[ -n "$(git status --porcelain -- maxmailin mailin Packages 2>/dev/null)" ]]; then
    say "WARNING: uncommitted source changes; the build will not match a commit."
fi
say "Commit: $(git rev-parse --short HEAD)  Version: build $BUILD"

if (( RUN_TESTS )); then
    say "== Purchase and gate tests (iOS simulator)"
    SIM=$(xcrun simctl list devices available | grep -m1 -E "iPhone .*\(" | grep -oE '[0-9A-F-]{36}')
    [[ -n "$SIM" ]] || fail "no available iPhone simulator"
    $XB test -project $PROJECT -scheme $SCHEME -destination "platform=iOS Simulator,id=$SIM" \
        -only-testing:maxmailinTests/StoreKitPurchaseFlowTests \
        -only-testing:maxmailinTests/PurchaseGateTests \
        -only-testing:maxmailinTests/PurchasePresentationTests \
        > "$OUT/tests.log" 2>&1 || fail "tests failed — see $OUT/tests.log"
    say "tests passed"
fi

# ExportOptions: App Store Connect, automatic signing; upload or local export.
make_options() {
    local destination=$1 file=$2
    cat > "$file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$destination</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
PLIST
}

verify_archive() {
    local platform=$1 archive=$2
    local app
    app=$(ls -d "$archive"/Products/Applications/*.app 2>/dev/null | head -1)
    [[ -d "$app" ]] || fail "$platform: no app inside the archive"
    local plist="$app/Info.plist"
    [[ -f "$plist" ]] || plist="$app/Contents/Info.plist"
    local bid ver bld
    bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
    ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
    bld=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
    say "$platform archive: $bid $ver ($bld)"
    [[ "$bid" == "$BUNDLE_ID" ]] || fail "$platform: bundle id is $bid, expected $BUNDLE_ID"
    [[ "$bld" == "$BUILD" ]] || fail "$platform: build is $bld, expected $BUILD"
    local ents
    ents=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null)
    if [[ "$platform" == macos ]]; then
        print -r -- "$ents" | grep -q "com.apple.security.app-sandbox" || fail "macos: app sandbox entitlement missing"
        print -r -- "$ents" | grep -q "com.apple.security.network.client" && fail "macos: network.client entitlement present"
        Scripts/verify-no-network.sh "$app" >> "$LOG" 2>&1 || fail "macos: verify-no-network.sh failed — see $LOG"
        say "macos: sandboxed, no network entitlement, verify-no-network PASS"
    fi
    # The StoreKit test file must not decide anything in a shipped build:
    # StoreKit ignores it outside Xcode, but a reviewer should not find it.
    [[ -e "$app/Products.storekit" || -e "$app/Contents/Resources/Products.storekit" ]] && \
        say "$platform: note — Products.storekit is bundled (ignored by StoreKit outside Xcode)"
    return 0
}

run_platform() {
    local platform=$1 destination
    [[ "$platform" == ios ]] && destination="generic/platform=iOS" || destination="generic/platform=macOS"
    local archive="$OUT/mailin-$platform.xcarchive"
    say "== $platform: archive"
    $XB archive -project $PROJECT -scheme $SCHEME -configuration Release -destination "$destination" \
        -archivePath "$archive" CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates "${AUTH[@]}" \
        > "$OUT/archive-$platform.log" 2>&1 || fail "$platform archive failed — see $OUT/archive-$platform.log"
    verify_archive "$platform" "$archive"

    local mode=export
    (( UPLOAD )) && mode=upload
    make_options "$mode" "$OUT/ExportOptions-$platform.plist"
    say "== $platform: $mode"
    $XB -exportArchive -archivePath "$archive" -exportPath "$OUT/export-$platform" \
        -exportOptionsPlist "$OUT/ExportOptions-$platform.plist" -allowProvisioningUpdates "${AUTH[@]}" \
        > "$OUT/export-$platform.log" 2>&1 || fail "$platform $mode failed — see $OUT/export-$platform.log"
    if (( UPLOAD )); then
        say "$platform: uploaded build $BUILD — it appears in App Store Connect ▸ TestFlight after processing (usually 5–30 min)"
    else
        say "$platform: signed for App Store Connect, not uploaded: $(ls -d "$OUT/export-$platform"/*.(ipa|pkg)(N) | head -1)"
    fi
}

[[ "$PLATFORM" == ios || "$PLATFORM" == both ]] && run_platform ios
[[ "$PLATFORM" == macos || "$PLATFORM" == both ]] && run_platform macos
say "DONE — log: $LOG"
