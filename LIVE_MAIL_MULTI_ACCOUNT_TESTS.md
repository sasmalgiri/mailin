# Live Mail multi-account tests (3.0 L9 — feature branch)

Three accounts: two on the same protocol (generic IMAP) and one different (Microsoft Graph). Every
row below is **NOT TESTED** on this branch; the automated rows run against a local Dovecot once the
`live-mail` branch has the account model (L2) and the sync engine (L4).

| # | Scenario | Expected | Automated? | Status |
|---|---|---|---|---|
| 1 | Add account A (IMAP), B (IMAP), C (Graph) | three Keychain items with distinct keys; no shared credential; combined Inbox labels each message's origin | yes (Dovecot ×2) + manual (Graph) | NOT TESTED |
| 2 | Fetch headers for all three | headers-first; bodies fetched only when opened; per-account quota respected | yes | NOT TESTED |
| 3 | Independent folder trees | A's folders never appear under B or C | yes | NOT TESTED |
| 4 | Mark read / flag / move in A | only A's server changes; B and C untouched (assert by re-fetch) | yes | NOT TESTED |
| 5 | Reply from a message received on B | From defaults to B, shown before editing and again at Send; Sent mapped to B | yes | NOT TESTED |
| 6 | Attempt to send from A with C's credentials | impossible by construction: draft carries one account id; the API takes no separate credential | unit test | NOT TESTED |
| 7 | Delete account B | B's Keychain item, records and cache removed; A and C intact; archive rows copied from B remain (archive is independent) | yes | NOT TESTED |
| 8 | Copy a message from C to the Archive | goes through `ArchiveImporting` only; account, UID and original MIME preserved; appears in Page 1 with source "C" | yes | NOT TESTED |
| 9 | Page 4 off | zero connections (`NetworkBaselineTests`); Live Mail types not resident (`hasLiveHost == false`) | yes | NOT TESTED |
| 10 | Network loss mid-sync | backoff; no partial record without its body flag; resumes | yes (Dovecot stop/start) | NOT TESTED |
| 11 | Two accounts at the same provider with the same username on different servers | no key collision (account id, not username, is the key) | unit test | NOT TESTED |
| 12 | Wrong-account send regression | a fault-injected mismatch between draft account and transport is refused before connecting | unit test | NOT TESTED |

Recording rule: an executed row gets the date, the account kinds (never the addresses), the
message counts and what was compared. Real-provider rows stay NOT TESTED until the owner's accounts
exist.
