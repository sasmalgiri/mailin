#!/bin/zsh
# OUT-05 / gate 5, second client: prepare a THROWAWAY Thunderbird profile that holds mailin's
# export in Local Folders. Owner permission 2026-11-09: a new profile created for this test only,
# no account, no mail sent, nothing to the network; removed afterwards (gate5_thunderbird_cleanup.sh).
#
#   Scripts/gate5_thunderbird_profile.sh [<gate5 dir>] [<profile dir>]
#     gate5 dir   default /tmp/mailin-gate5 (MailClientHandoffFixtureTests with MAILIN_GATE5_OUT)
#     profile dir default /tmp/tb-mailin-test (created with: thunderbird -CreateProfile "mailin-test <dir>",
#                 or — 2026-11-18, no registry at all — an empty directory used with --profile <dir>)
# Start (2026-11-18 form, nothing written outside /tmp, no window):
#   CFFIXED_USER_HOME=/tmp/tb-home HOME=/tmp/tb-home thunderbird --headless --profile <dir> -no-remote \
#     -offline --marionette --remote-allow-system-access
#
# Route = the export sheet's "copy into Local Folders" route: an mbox file placed in the profile's
# Mail/Local Folders directory (no extension) is a folder Thunderbird reads and indexes itself.
set -euo pipefail
G5=${1:-/tmp/mailin-gate5}
PROF=${2:-/tmp/tb-mailin-test}
[[ -d $PROF ]] || { echo "no profile at $PROF — mkdir it (used with --profile) or run: thunderbird -CreateProfile \"mailin-test $PROF\"" >&2; exit 1; }
LF="$PROF/Mail/Local Folders"
mkdir -p "$LF"
# Every per-folder mbox (synthetic run: Inbox, Projects; real run 2026-11-18: one per source folder)
# and every hand-off part, each as its own Local Folders folder.
# Thunderbird hashes a folder file name longer than 55 characters (it then shows an empty folder
# under another name), so the name is cut to 48 after "mailin-" — the read-back cuts the same way.
for f in "$G5"/folders/*.mbox; do n=$(basename "$f" .mbox); cp "$f" "$LF/mailin-${n[1,48]}"; done
for f in "$G5"/mailin-handoff/mailin-handoff-*.mbox; do cp "$f" "$LF/$(basename "$f" .mbox)"; done
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
// 2026-11-18: no macOS Contacts directory (Thunderbird asked for Contacts access); everything in the
// main process (this Mac refused Thunderbird's helper processes: sandbox extension EPERM).
user_pref("ldap_2.servers.osx.position", 0);
user_pref("ldap_2.servers.osx.uri", "");
user_pref("browser.tabs.remote.autostart", false);
user_pref("fission.autostart", false);
user_pref("extensions.webextensions.remote", false);
user_pref("layers.gpu-process.enabled", false);
user_pref("network.process.enabled", false);
user_pref("media.rdd-process.enabled", false);
user_pref("media.utility-process.enabled", false);
user_pref("dom.ipc.processPrelaunch.enabled", false);
EOF
ls -la "$LF"
