# Proving the offline claim (task D1)

The claim is: **mailin cannot reach the network.** Until now it rested on two
things that are true but are not proof.

| Support | Why it is not proof |
|---|---|
| `NO_NETWORK_BUILD` compilation condition in both configurations | A build setting. Changeable, and invisible in the artifact a reviewer receives. |
| A measured Release run showing 0 network sockets | One run. Absence of observed behaviour is not absence of capability. |

What does survive a challenge is the **signed binary**: under the App Sandbox,
a process with no network entitlement cannot open a socket regardless of what
its code asks for. That is enforced by the kernel, not by our intentions.

Status: implemented 2026-09-24; **check 3 rewritten 2026-11-14 for v4.0** (see the
last section: the package's transport code is linked into the offline binary, so the
proof is "no entitlement + no reachable entry point", not "no transport code").

---

## The three artifacts

### 1. `Scripts/verify-no-network.sh` — checks the built app

```
Scripts/verify-no-network.sh /path/to/mailin.app
Scripts/verify-no-network.sh            # finds the newest Release build
```

Four groups of checks, exiting non-zero on the first failure:

| Check | What it proves |
|---|---|
| `com.apple.security.app-sandbox` present | entitlements are actually enforced for this build |
| `com.apple.security.network.client` not granted | the process cannot make outgoing connections |
| `com.apple.security.network.server` not granted | it cannot listen |
| `mailin.offline.attested` in the binary's strings | `NO_NETWORK_BUILD` was defined for **this** build, not merely for some build |
| `mailin.online.capable` absent | this is not a `MAILIN_CONNECTED_MAIL` build |
| app entry points absent (Swift-mangled names, searched in `nm` and `strings`): `ConnectedMailProductionTransports`, `ConnectedMailProduction`, `PolicyCheckedTokenTransport`, `GmailConnector`, `OutlookConnector`, `IMAPClient`, `SMTPClient`, `CloudAIManager` | no app code path that constructs a network transport is compiled into this build |
| no `MailinGmailClientID` / `MailinGraphClientID` / `MailinGraphRedirectURI` / `MailinGmailSignInMode` in `Info.plist` | the connected edition's Info.plist was not used |
| `Network` / `CFNetwork` direct link | **reported as a NOTE since v4.0, not a failure** — the package target MailConnectivity links Network.framework (see below) |
| no `NSAppTransportSecurity` in `Info.plist` | no ATS exceptions were declared |

`URLSession` symbols are reported as a **note, not a failure**: Foundation
exports them whatever we do, and the entitlement check is what proves they
cannot be used. Calling that a failure would make the script cry wolf.

### 2. `maxmailin/NoNetworkAttestation.swift` — the in-app read

- `buildMarker` — the string the script greps for. Compiled as
  `mailin.offline.attested` only under `NO_NETWORK_BUILD`, so its presence in a
  binary is evidence about that binary.
- `verdict()` — reads **this process's own** signed entitlements via Code
  Signing Services (`SecCodeCopySelf` → `SecCodeCopyStaticCode` →
  `SecCodeCopySigningInformation`, `kSecCodeInfoEntitlementsDict`).
- `networkIsStructurallyImpossible` is true **only** when entitlements are
  readable AND the app is sandboxed AND neither network entitlement is
  granted. A build flag alone does not qualify.

Two deliberate honesty constraints:

- **An unreadable entitlement dictionary reads as "cannot demonstrate", not
  as "safe."** `entitlementsAreEnforceable` goes false, and
  `networkIsStructurallyImpossible` with it.
- **iOS is reported truthfully.** Code Signing Services is macOS-only, and
  iOS grants network access to every app — there is no entitlement to
  withhold. So on iOS the verdict says the build flag is the only protection
  rather than implying the sandbox enforces something it does not.

### 3. About panel — the claim next to its evidence

A second row under "Offline & Private" shows `verdict().summary`, so the
marketing sentence and the enforced fact sit together. When the sandbox is
not doing the enforcing, that row says so.

---

## Entitlements as shipped

`maxmailin/mailin.entitlements` (macOS):

```
com.apple.security.app-sandbox              true
com.apple.security.print                    true
com.apple.security.files.user-selected.read-write  true
com.apple.security.files.bookmarks.app-scope       true
```

No `network.client`, no `network.server`. `mailin_offline.entitlements`
matches. `mailin_iOS.entitlements` is empty, which on iOS means the defaults
apply — hence the platform caveat above.

---

## What is still owed

- **Run the script against a signed Release archive.** Until then this
  document describes a mechanism, not a result.
- **A separate `NO_NETWORK_BUILD` configuration** was the original phrasing of
  D1. It is deliberately not implemented: a third configuration would need its
  own maintenance and would still be a build setting — the same class of
  evidence `NO_NETWORK_BUILD` already is. The entitlement check makes the extra
  configuration unnecessary, because it constrains the artifact rather than
  the build. If a reviewer specifically wants a named configuration, adding
  one is a project-file change for the owner to make in Xcode.
- **CI wiring.** The script is written to be a build-phase or CI gate
  (non-zero exit on failure); nothing invokes it automatically yet.

---

## v4.0 (V4-14, 2026-11-12): offline proof unchanged; the connected edition is checked differently

- **Offline edition** (`Release`, `Debug`, enterprise): `NO_NETWORK_BUILD` is still defined,
  `mailin/mailin.entitlements` still has no network key, `NoNetworkAttestation.buildMarker` is
  `mailin.offline.attested`, and `Scripts/verify-no-network.sh` must PASS. **Correction 2026-11-14:** the
  package's transport code IS linked into the offline binary — see "What the offline binary contains" below.
  The app-side transports and entry points are gated `#if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD` and are
  absent (0 IMAPClient / SMTPClient / GmailConnector / OutlookConnector / ConnectedMailProductionTransports /
  CloudAIManager symbols).
- **Connected edition** (`Release-Connected`, `MAILIN_CONNECTED_MAIL`, signed with
  `mailin/mailin-connected.entitlements`): this document's claim does **not** apply and its script is expected to
  report "online capable". It is checked instead by `Scripts/check-connected-release.sh <app>` (T47): marker
  `mailin.online.capable`; sandbox on, `network.client` granted, `network.server` not granted; real Gmail / Graph
  client IDs and the `msauth.<bundle id>://auth` redirect in `Info.plist` (no placeholders); 0 `CloudAIManager`
  symbols. The same Info.plist rules run in `V414ClaimsTests.testT47_thisConnectedReleaseBuildHasRealClientIDs`.
- **Run-time gate in the connected edition**: `MailNetworkPolicy` (off on a fresh install until the Live Mail page /
  `connectedMail` capability is on; per-account modes all off; per-account host binding; AI hosts and remote
  content always refused). Hosts it can permit, per provider: `NETWORK_AND_PRIVACY_MATRIX.md` § v4.
- **In-app wording follows the binary**: About shows "Offline & Private — No account, no mail servers…" only when
  `ConnectedBuildFeatures.mailTransportsCompiled` is false; the connected edition shows "Private by design" with
  text that depends on whether Connected mail is on (`EditionPrivacyClaim`, `V414ClaimsTests`).

---

## v4.0 correction (2026-11-14): what the offline binary contains, and why it still cannot connect

**What is linked.** `Packages/ArchiveCore/Package.swift` ships ONE library product, `ArchiveCore`, made of two
targets: `ArchiveCore` and `MailConnectivity` (V4-02/V4-03, so the app can `import MailConnectivity` without a
project-file change). The offline app links that product, so the offline binary contains MailConnectivity's
transport code: `IMAPTransport` and `SMTPStream` / `SMTPSubmitter` (Network.framework, `NWConnection`),
`GmailHTTPTransport`, `GraphTransport`, `APISendSubmitters`, `APIActionExecutors`, `OAuthSession` (`URLSession`).
Measured on the unsigned offline Release build of 7d35777 (2026-11-14): `otool -L` lists
`Network.framework` directly; 30 `NWConnection` symbol/string references; `IMAPTransport` and
`GmailHTTPTransport` type names present; 4 undefined `URLSession` symbols. The earlier statement in this file that
the transports are "absent from this binary" was true of the app's own legacy transports only.

**Why it cannot run.**

1. **No network entitlement** (check 1, the binding proof). The offline configurations sign with
   `mailin/mailin.entitlements` (app-sandbox, print, user-selected read-write, app-scope bookmarks — no
   `com.apple.security.network.client`, no `network.server`). Under the App Sandbox the kernel refuses every
   outbound and inbound socket of this process, whichever code (ours, the package's, Foundation's) asks.
2. **No app code path constructs it.** Every app-side place that builds a transport or an adapter with one is
   compiled only under `MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD`: `ConnectedMailProductionTransports`,
   `ConnectedMailProduction.dependencies()` (`ConnectedMailRuntime.swift`, which builds `URLSessionGraphTransport`,
   the Gmail / IMAP adapters and `PolicyCheckedTokenTransport`), and the legacy `GmailConnector`,
   `OutlookConnector`, `IMAPClient`, `SMTPClient`. In the offline build `ConnectedBuildFeatures.mailTransportsCompiled`
   is false, so `ConnectedMailRuntime.makeProductionDependencies()` returns nil and `capabilityChanged` returns
   at once; `MailNetworkPolicy` answers `.notCompiled` to every request; the Live Mail page is excluded
   (`CapabilityWiring`). Check 3 proves the gated entry points are absent from the artifact.
3. **Edition markers.** `mailin.offline.attested` present (check 2), `mailin.online.capable` absent and no
   connected Info.plist key (check 3).

So the honest offline claim is: *the offline build contains the package's mail transport code, but the sandbox
gives it no network access and no code in the app can start it.* Making the code itself absent would need the
package split into two products and a project-file change in Xcode (owner; not done for 4.0).

**Run 2026-11-14** (unsigned offline Release, `xcodebuild … -configuration Release … CODE_SIGNING_ALLOWED=NO`,
7d35777 + this change): check 1 FAIL "could not read entitlements — is the app signed?" (expected for an unsigned
build — run the script again on the signed archive before any offline claim); check 2 PASS; check 3 all 14 PASS
(markers, 8 entry points, 4 Info.plist keys, CFNetwork; Network.framework NOTE, URLSession NOTE); check 4 PASS —
16 of 17 checks pass. The previous check 3 failed on the same binary with "Network is linked directly".
`Scripts/verify-no-network-selftest.sh` gains two shapes (a planted `ConnectedMailProductionTransports` symbol, a
connected Info.plist key), both judged FAIL as required; 13/13 shapes judged correctly.
