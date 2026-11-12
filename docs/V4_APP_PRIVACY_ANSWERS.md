# App Store Connect ▸ App Privacy — draft answers for v4.0 (V4-14)

Draft for the owner. **The owner gives the final answers in App Store Connect**; Apple's label depends on what is
actually collected and by whom (plan §10, [P21]) — a network entitlement alone decides nothing. Reasoning below is
from the code at d4a3ec3 (inventory: [`PRIVACY_V4_DRAFT.md`](PRIVACY_V4_DRAFT.md)).

Apple's definitions used: data is **collected** when it is transmitted off the device in a way that lets *you
(the developer) and/or your third-party partners* access it for longer than needed to service the request in real
time. **Third-party partners** are analytics tools, ad networks, SDKs or other parties *whose code is in the app or
with whom the developer shares data*.

## 1. What mailin's developer receives — nothing

| Check | Finding | Evidence |
|---|---|---|
| Developer server, relay, proxy | none exists | no backend; every URL host in `MailConnectivity` is Google, Microsoft or the user's IMAP/SMTP host |
| Analytics / crash / ad SDKs | none linked | Package.swift: only `CLibArchiveRAR` (libarchive, no network); no remote package references in the project |
| Telemetry, diagnostics upload | none | `DiagnosticsCenter` writes local files only; exports happen only when the user saves/shares a file |
| Support submissions from inside the app | none (no in-app form; the user may e-mail support themselves) | — |
| Tracking (ATT) | none; `NSPrivacyTracking = false`, no tracking domains | `maxmailin/PrivacyInfo.xcprivacy` |
| Purchases | StoreKit; Apple's own data, not declared by the developer | — |
| AI | no cloud AI compiled; scaffolding transport refuses all | SCAF-01…05 |

## 2. What goes to the user's own mail provider

In the connected edition, at the user's request: mail content and metadata (Gmail/Graph/IMAP capture is a download
*to* the device; sending uploads the user's message *to* their provider; server actions send message IDs and the
requested change), and OAuth tokens / app passwords to the provider that issued them.

The provider here is the **user's own service**, reached directly by the device, under the user's own account and
contract with that provider. The developer has no access to it and no agreement with the provider about the user's
data. On Apple's definition this is the app acting as a client for the user's account, as any mail app does; it is
not the developer or a developer partner obtaining the data.

## 3. Draft answers

**Recommended (defensible on §1–§2): "Data Not Collected"** for both editions — the developer and no partner of the
developer collect any data type.

**Alternative, if the owner prefers the conservative reading** (treating the mail providers' receipt of sent mail as
collection by a third party): declare

| Data type | Purpose | Linked to user | Tracking |
|---|---|---|---|
| Emails or Text Messages | App Functionality | Yes (it is the user's account) | No |
| User ID (the account address used to sign in) | App Functionality | Yes | No |

and add the same entries to `NSPrivacyCollectedDataTypes` in `PrivacyInfo.xcprivacy` (today an empty array,
consistent with "Data Not Collected"). The label and the manifest must say the same thing.

Either way, write in the App Review notes and on the privacy page that connected mail is optional, off by default,
and goes directly to the user's provider (drafts in `V4_STORE_METADATA_DRAFT.md`, `privacy/v4-connected-draft.html`).

## 4. Questions only the owner can decide

1. "Data Not Collected" or the conservative declaration in §3? (One label per app record: the offline and connected
   editions share bundle `com.ecosanskriti.mailin`, so the label must be true of the connected build.)
2. Will the connected edition replace the offline edition on the public App Store, or ship as a separate product /
   later version? (Decides when the live privacy page is replaced and whether a separate app record is needed.)
3. Is a support channel planned that receives user data (e-mail with attached diagnostics, a web form)? If yes,
   reconsider "Data Not Collected" for that path.
4. Is Apple's opt-in crash-log sharing (App Store Connect ▸ crashes) used for support? Apple collects that, not the
   app; confirm the owner is comfortable not declaring it (Apple's guidance has treated it as Apple's data).
5. Age rating / "unrestricted web access": the sign-in window shows only provider sign-in pages; answer No unless
   Apple's questionnaire is read otherwise.
6. Export-compliance (`ITSAppUsesNonExemptEncryption = NO` today): the connected build uses only Apple's TLS
   (Network.framework / URLSession) and CryptoKit — standard exempt encryption; confirm the answer stays No.
7. Google's Limited Use and Microsoft's publisher terms: confirm the published privacy page states what the
   registrations state (`V4_PROVIDER_REGISTRATION.md` §1.5, §2.5).
