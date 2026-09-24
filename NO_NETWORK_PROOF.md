# Proving the offline claim (task D1)

The claim is: **mailin cannot reach the network.** Until now it rested on two
things that are true but are not proof.

| Support | Why it is not proof |
|---|---|
| `OFFLINE_MODE` compilation condition in both configurations | A build setting. Changeable, and invisible in the artifact a reviewer receives. |
| A measured Release run showing 0 network sockets | One run. Absence of observed behaviour is not absence of capability. |

What does survive a challenge is the **signed binary**: under the App Sandbox,
a process with no network entitlement cannot open a socket regardless of what
its code asks for. That is enforced by the kernel, not by our intentions.

Status: **implemented 2026-09-24, not yet executed.** The script has never
been run because nothing has been built yet.

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
| `mailin.offline.attested` in the binary's strings | `OFFLINE_MODE` was defined for **this** build, not merely for some build |
| `Network` / `CFNetwork` not linked directly | no transport stack was pulled in deliberately |
| no `NSAppTransportSecurity` in `Info.plist` | no ATS exceptions were declared |

`URLSession` symbols are reported as a **note, not a failure**: Foundation
exports them whatever we do, and the entitlement check is what proves they
cannot be used. Calling that a failure would make the script cry wolf.

### 2. `maxmailin/NoNetworkAttestation.swift` — the in-app read

- `buildMarker` — the string the script greps for. Compiled as
  `mailin.offline.attested` only under `OFFLINE_MODE`, so its presence in a
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
  evidence `OFFLINE_MODE` already is. The entitlement check makes the extra
  configuration unnecessary, because it constrains the artifact rather than
  the build. If a reviewer specifically wants a named configuration, adding
  one is a project-file change for the owner to make in Xcode.
- **CI wiring.** The script is written to be a build-phase or CI gate
  (non-zero exit on failure); nothing invokes it automatically yet.
