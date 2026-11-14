#!/bin/zsh
# Owner's TestFlight purchase checklist, simulated on the iPad simulator.
cd "${0:A:h:h}"
SIM=${SIM:-7922C0FA-9E06-4ACC-80F9-DF8107F7C1C3}  # iPad Pro 13-inch simulator; override with SIM=<udid>
L=${PURCHASE_LOG:-/tmp/mailin-purchase.log}
XB=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
: > $L
xcrun simctl boot $SIM 2>/dev/null
D="platform=iOS Simulator,id=$SIM"
# Runs one test; ends xcodebuild 30 s after the test reports, since it can
# hang after the run (seen 2026-10-08).
step() {
  local name=$1 test=$2 out=${L%.log}-$1.log
  $XB test-without-building -project maxmailin.xcodeproj -scheme maxmailin -destination "$D" -only-testing:$T/$test > $out 2>&1 &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    if grep -q "Test Suite 'Selected tests' \(passed\|failed\)" $out; then
      sleep 30; kill $pid 2>/dev/null; break
    fi
    sleep 5; waited=$((waited+5)); [[ $waited -gt 900 ]] && { kill $pid; echo "$name TIMEOUT" >> $L; break; }
  done
  cat $out >> $L
  if grep -q "Test Suite 'Selected tests' passed" $out; then echo "$name exit=0" >> $L; else echo "$name exit=1" >> $L; fi
}
T=maxmailinUITests/MailinClickThroughUITests
echo "== build" >> $L
$XB build-for-testing -project maxmailin.xcodeproj -scheme maxmailin -destination "$D" -jobs 1 > ${L%.log}-build.log 2>&1
echo "build exit=$?" >> $L
echo "== 1 buy monthly" >> $L
step step1 testPurchase1_buyMonthlyUnlocksFeatures
echo "== wipe the app's data (what a reinstall erases)" >> $L
BID=$(xcrun simctl listapps $SIM 2>/dev/null | grep -o '"com.ecosanskriti.mailin[^"]*"' | head -1 | tr -d '"')
BID=${BID:-com.ecosanskriti.mailin}
xcrun simctl terminate $SIM $BID 2>/dev/null
DATA=$(xcrun simctl get_app_container $SIM $BID data)
echo "data container: $DATA ($(du -sh "$DATA" | cut -f1) before)" >> $L
for dir in Documents Library tmp; do rm -rf "$DATA/$dir"; mkdir -p "$DATA/$dir"; done
for g in $(xcrun simctl get_app_container $SIM $BID groups 2>/dev/null | awk '{print $2}'); do rm -rf "$g"/*; done
echo "after wipe: $(du -sh "$DATA" | cut -f1)" >> $L
echo "== 2 reinstall + restore" >> $L
step step2 testPurchase2_reinstallThenRestore
echo "== 3 buy lifetime" >> $L
step step3 testPurchase3_buyLifetime
echo "done" >> $L
