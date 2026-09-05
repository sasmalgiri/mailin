# mailin — Enterprise Deployment Guide (MDM)

mailin is local-first: the app processes email archives entirely on the device. There is no
server component, no tenant, and no vendor data processing — IT deploys an app, not a
service. This guide covers managed deployment via MDM (Jamf, Kandji, Intune, Mosyle, etc.)
using Apple's standard Managed App Configuration.

## Requirements

- macOS 14.6+ / iOS 17.6+ devices enrolled in your MDM
- Devices MUST have a device passcode set when `requireBiometricLock` is enforced —
  a device with no authentication method cannot satisfy the lock and mailin will
  disable it to prevent permanent lockout (this is logged)
- App distribution: Apple Business Manager (see licensing note below)

## Managed App Configuration keys

Push a configuration dictionary for bundle id `com.ecosanskriti.mailin`
(standard `com.apple.configuration.managed` mechanism):

| Key | Type | Effect |
|---|---|---|
| `orgName` | string | Shown in About and report provenance ("Managed deployment — <org>") |
| `examinerName` | string | Preset examiner identity; used for who-stamps and sealed receipts |
| `disableCloudAI` | bool | **Hard off** for all cloud AI. The in-app toggle is disabled and cannot re-enable it. All processing stays on device |
| `requireBiometricLock` | bool | Forces the biometric/passcode app lock on; users cannot disable it |
| `caseNumberPrefix` | string | Preset prefix for case and Bates numbering |
| `licenseKey` | string | Enterprise pilot licensing (interim mechanism; see licensing) |

Example (Jamf-style plist payload):

```xml
<dict>
    <key>orgName</key><string>Acme Legal LLP</string>
    <key>examinerName</key><string></string>
    <key>disableCloudAI</key><true/>
    <key>requireBiometricLock</key><true/>
    <key>caseNumberPrefix</key><string>ACME</string>
</dict>
```

## What the policies guarantee

- `disableCloudAI=true`: the cloud AI provider layer reports not-ready, the stored
  toggle is forced off at launch and on every attempted enable. Combined with mailin's
  default (cloud AI off unless a user opts in with their own key), a managed fleet
  provably sends nothing to any AI provider.
- `requireBiometricLock=true`: the app locks at launch and on the configured triggers;
  the Settings toggle cannot turn it off.
- Sealed documents: every numbered work product mailin posts carries a sealed receipt
  (SHA-256 of the content + Ed25519 signature + public key). Any post-hoc edit fails
  verification with a content mismatch. `examinerName` from managed config is recorded
  as the sealing identity.

## Licensing (current state)

Consumer in-app purchases do not flow through Apple Business Manager volume purchasing.
Until the dedicated enterprise SKU ships, pilot deployments use the `licenseKey` managed
key. Contact sasmalgiri@gmail.com for pilot licensing.

## Data flow summary (for security review)

- Import: user-provided archive files (.mbox/.pst/.eml/.emlx/.msg/.nsf/.ost) parsed
  on-device into a local SQLite store (Application Support, App Sandbox)
- Processing: search/index/AI (Apple NaturalLanguage, Apple Intelligence) on-device
- Network: none in normal operation. The only optional network path is user-opt-in
  cloud AI with a user-supplied API key — and `disableCloudAI` removes it fleet-wide
- Keys: HMAC audit-log key and Ed25519 signing key live in the device Keychain
- Telemetry: none. mailin has no analytics SDKs and collects nothing
