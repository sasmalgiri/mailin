#!/bin/zsh
# OUT-05 / gate 5, second client: remove the throwaway Thunderbird profile after the run.
#   Scripts/gate5_thunderbird_cleanup.sh [<profile dir>] [--remove-registry]
# Quits Thunderbird, deletes the profile directory and its entry. --remove-registry deletes
# ~/Library/Thunderbird and ~/Library/Caches/Thunderbird entirely — ONLY for a Mac where they did
# not exist before the run (2026-11-09: neither existed; Thunderbird had never been started).
set -euo pipefail
PROF=${1:-/tmp/tb-mailin-test}
# Quit by signal, not Apple Events: `tell application "Thunderbird" to quit` LAUNCHES Thunderbird
# when it is not running, and asks for Automation permission (2026-11-18).
pkill -x thunderbird 2>/dev/null || true
for i in {1..20}; do pgrep -x thunderbird >/dev/null || break; sleep 1; done
pgrep -x thunderbird >/dev/null && { echo "Thunderbird still running" >&2; exit 1; }
rm -rf "$PROF"
# 2026-11-18 form: Thunderbird's whole home was redirected into /tmp/tb-home (CFFIXED_USER_HOME).
# Its Desktop folder gets an "everyone deny delete" ACL, removed first.
[[ -d /tmp/tb-home ]] && { chmod -R -N /tmp/tb-home 2>/dev/null; rm -rf /tmp/tb-home; }
# A LaunchServices start (open -a) also leaves cfprefsd's org.mozilla.thunderbird domain in the real
# ~/Library/Preferences — removed by --remove-registry below (the headless start writes none).
if [[ ${2:-} == --remove-registry ]]; then
  rm -rf "$HOME/Library/Thunderbird" "$HOME/Library/Caches/Thunderbird" "$HOME/Library/Application Support/Thunderbird"
  defaults delete org.mozilla.thunderbird 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/org.mozilla.thunderbird.plist"
else
  echo "profile removed; edit ~/Library/Thunderbird/profiles.ini to drop the mailin-test entry"
fi
ls -d "$PROF" "$HOME/Library/Thunderbird" "$HOME/Library/Caches/Thunderbird" "$HOME/Library/Application Support/Thunderbird" 2>&1 || true
