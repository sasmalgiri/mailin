#!/bin/zsh
# OUT-05 / gate 5, second client: prepare a THROWAWAY Thunderbird profile that holds mailin's
# export in Local Folders. Owner permission 2026-11-09: a new profile created for this test only,
# no account, no mail sent, nothing to the network; removed afterwards (gate5_thunderbird_cleanup.sh).
#
#   Scripts/gate5_thunderbird_profile.sh [<gate5 dir>] [<profile dir>]
#     gate5 dir   default /tmp/mailin-gate5 (MailClientHandoffFixtureTests with MAILIN_GATE5_OUT)
#     profile dir default /tmp/tb-mailin-test (created with: thunderbird -CreateProfile "mailin-test <dir>")
#
# Route = the export sheet's "copy into Local Folders" route: an mbox file placed in the profile's
# Mail/Local Folders directory (no extension) is a folder Thunderbird reads and indexes itself.
set -euo pipefail
G5=${1:-/tmp/mailin-gate5}
PROF=${2:-/tmp/tb-mailin-test}
[[ -d $PROF ]] || { echo "no profile at $PROF — run: thunderbird -CreateProfile \"mailin-test $PROF\"" >&2; exit 1; }
LF="$PROF/Mail/Local Folders"
mkdir -p "$LF"
cp "$G5/folders/Inbox.mbox" "$LF/mailin-Inbox"
cp "$G5/folders/Projects.mbox" "$LF/mailin-Projects"
cp "$G5/mailin-handoff/mailin-handoff-0001.mbox" "$LF/mailin-handoff-0001"
cat > "$PROF/user.js" <<'EOF'
// gate 5 throwaway profile: Local Folders only, offline, no wizard, no updates, no telemetry.
user_pref("mail.accountmanager.accounts", "account1");
user_pref("mail.accountmanager.localfoldersserver", "server1");
user_pref("mail.account.account1.server", "server1");
user_pref("mail.server.server1.directory-rel", "[ProfD]Mail/Local Folders");
user_pref("mail.server.server1.hostname", "Local Folders");
user_pref("mail.server.server1.name", "Local Folders");
user_pref("mail.server.server1.type", "none");
user_pref("mail.server.server1.userName", "nobody");
user_pref("mail.provider.enabled", false);
user_pref("mail.shell.checkDefaultClient", false);
user_pref("mailnews.start_page.enabled", false);
user_pref("mail.rights.version", 1);
user_pref("mail.spotlight.firstRunDone", true);
user_pref("mail.winsearch.firstRunDone", true);
user_pref("network.online", false);
user_pref("offline.startup_state", 2);
user_pref("app.update.enabled", false);
user_pref("app.update.auto", false);
user_pref("app.update.checkInstallTime", false);
user_pref("extensions.update.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("browser.safebrowsing.malware.enabled", false);
user_pref("browser.safebrowsing.phishing.enabled", false);
user_pref("mailnews.message_display.disable_remote_image", true);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.prefetch-next", false);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("mail.tabs.drawInTitlebar", true);
EOF
ls -la "$LF"
