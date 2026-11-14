# Fixture acquisition — directive 2026-11-07 §3 (public samples)

The owner's second fixture pack ("Online mail fixtures and S/MIME") had not arrived on 2026-11-07.
**2026-11-09 (R9):** the pack was supplied as a ChatGPT library file (`libfile_d408d1057be08191aeabaa4482bc175d`)
and has never been saved on this Mac — not under the fixture root, ~/Downloads (the 2026-11-07 zip there is the
public OFT/archive/Word pack), ~/Documents, ~/Desktop, /tmp or Spotlight. The COMP-14 S/MIME run used a
disposable identity and `<root>/smime/enveloped.p7m` / `signed.p7m`, removed after the run. Install location
when it arrives: `<root>/owner-pack/` with `owner-pack/SHA256SUMS`; both rows stay `pending` until then.
**2026-11-09 (R9, owner permission of the same day):** `<root>/owner-pack/` was made on this Mac instead —
`smime/` (synthetic S/MIME set: throwaway CA, Alice RSA + Bob EC P-256 `.p12` with password
`mailin-fixture-2026`, signed / enveloped / signed-then-enveloped / tampered messages; OpenSSL 3.5.1,
`Scripts/r9_make_smime_fixtures.sh`) and `native/` (six synthetic messages imported into Apple Mail 16.0 and
exported back with Mailbox ▸ Export Mailbox… = an Apple-Mail-written mbox, plus Mail's source of each
message as .eml). Each directory has a README (how made, synthetic, passwords); 27 files are pinned in
`ExternalFixtures.ownerPackDigests` and tested by `OwnerPackFixtureTests`. The S/MIME row is no longer
pending. The native Outlook for Mac OLM of the same messages is still `pending`: Outlook is not installed.
**2026-11-09 (CLOSE-04), correction:** the owner's supplied pack WAS on this Mac —
`~/Downloads/Mailin_Online_Mail_Fixtures_and_SMIME_2026-11-07.zip` (ZIP SHA-256
`3b4f0413529114fa28876c664ada80ac90432aea6690b101503ec2b5e6a7b71e`, 51 entries; the earlier search took the
other 2026-11-07 zip in ~/Downloads, `Mailin_Public_Test_Fixtures_2026-11-07.zip`, for the only one). Its
native cross-format pair is staged at `<root>/native-pack-20261003/` (own `SHA256SUMS`, lines copied unchanged
from the zip's; `PROVENANCE.md`; the producer `manifest.json` and `native_source_manifest.json` /
`native_sources.json` both kept), apart from `owner-pack/`: `native-apple-20261003/outlook/native-outlook.olm`
(Outlook for Mac 16.112.4, Legacy mode), the Apple Mail 16.0 export `native-apple-20261003/mail/Root/…`,
`paired-mail/native-mail.eml` (derived from the MBOX) and `oracles/native_cross_format.json`. It covers ONE
mail — subject, From, To, HTML, two attachments by bytes/SHA-256 and the inline CID; the MBOX has no Date or
Message-ID — not the six owner-pack/native/ messages, and no native PST/OST/NSF of it exists. Seven files are
pinned in `ExternalFixtures.nativePackDigests`; acceptance: `NativeOLMPairFixtureTests`. No row is pending.
The files the directive table names are public, so they were fetched from their upstream repositories
with the attempts below recorded in order. Nothing here was fabricated: a row says "obtained" only
when the bytes are on disk with the SHA-256 shown.

Fixture root (outside the repository): `$MAILIN_FIXTURE_ROOT`, default `~/Downloads/Mail/Fixtures`.
Each pack directory carries a `SHA256SUMS` (`shasum -a 256` format, paths relative to the pack) that
`ExternalFixtures` verifies before a test may use a file. A copy of this note lives at the fixture
root and in `Packages/ArchiveCore/Tests/ArchiveCoreTests/Fixtures/`.

## Attempts, in order

| # | Target | URL / method | Result |
|---|---|---|---|
| 1 | GitHub code search `filename:SampleOLM.olm` | `https://api.github.com/search/code?q=filename:SampleOLM.olm` | not tried — requires authentication; replaced by tree listings (2–5) |
| 2 | Aspose .NET tree | `https://api.github.com/repos/aspose-email/Aspose.Email-for-.NET/git/trees/master?recursive=1` | 200, 954 entries, not truncated. Found `Examples/Data/MAPI/SampleOLM.olm`, `…/SampleOstFile.ost`, `…/PersonalStorageFile.ost`, `…/test.ost`, `Examples/Data/Email/SampleNSF.nsf`, `Examples/Data/MBOX/ExampleMbox.mbox` |
| 3 | Aspose Java tree | `https://api.github.com/repos/aspose-email/Aspose.Email-for-Java/git/trees/master?recursive=1` | 200, 972 entries. `Examples/src/main/resources/outlook/SampleOLM.olm`, `…/email/SampleNSF.nsf` — blob SHAs identical to the .NET copies (byte-identical, verified by download: same SHA-256) |
| 4 | Aspose Python-via-.NET tree | `…/aspose-email/Aspose.Email-for-Python-via-NET/git/trees/master` and `…/main` | 404 both — repository not reachable under that name |
| 5 | java-libpst tree | `https://api.github.com/repos/rjohnsondev/java-libpst/git/trees/master?recursive=1` | 200, 64 entries. `src/test/resources/example-2013.ost` (16,818,176 bytes), `dist-list.pst`, `passworded.pst` |
| 6 | libpff wiki | `https://github.com/libyal/libpff/wiki` | 200 — pages Building / Development / Testing / Troubleshooting; no test corpus or `.ost` sample is published there |
| 7 | Native `.olm` converter repos (web search) | `emaV/olm-converter` (README: keeps personal archives out of VCS), `PeterWarrington/olm-convert`, `lukerf89/olm-to-eml-converter`, `Magy/OLM-Reader`, `0angelic0/olm_calendar_to_csv` | no sample archive shipped in those repositories |
| 8 | `teverett/OLMReader` tree | `https://api.github.com/repos/teverett/OLMReader/git/trees/master?recursive=1` | 200. `src/test/resources/Outlook16/outlook_example.olm` (1,404,748 bytes) and `…/bill_rapp.olm` (5,781,944 bytes) — native Outlook 16 for Mac exports |
| 9 | Apache Tika mail-module test documents | `https://api.github.com/repos/apache/tika/contents/tika-parsers/tika-parsers-standard/tika-parsers-standard-modules/tika-parser-mail-module/src/test/resources/test-documents?ref=main` | 200. `testEMLX_multipart_html.emlx`, `testEMLX_single_part_html.emlx`, `testMBOX_complex.mbox`, `testMBOX_lengthy_x-headers.mbox`, `complex.mbox`, `single_mail.mbox` |
| 10 | `SampleNSF.nsf` elsewhere (Domino SDK mirrors, `jnotes`, `domino-jna`) | not searched further — the exact public sample the directive names is the Aspose one, obtained in 2 |

Downloads were made with `curl -L` from `https://raw.githubusercontent.com/<owner>/<repo>/master/<path>`
(Tika: `…/apache/tika/main/<path>`), sizes checked against the tree entries.

## Files obtained

Licence texts were read from each repository's `LICENSE` file on the same day.

| File | Source URL (raw) | Obtained | Licence (as stated by the repo) | Bytes | SHA-256 |
|---|---|---|---|---|---|
| `opensource/aspose-email-net/SampleOLM.olm` | `https://raw.githubusercontent.com/aspose-email/Aspose.Email-for-.NET/master/Examples/Data/MAPI/SampleOLM.olm` (identical: `…/Aspose.Email-for-Java/master/Examples/src/main/resources/outlook/SampleOLM.olm`) | yes | MIT (Aspose Pty Ltd, 2001-2016) | 997,508 | `a3aa54a01157618b1a45949f25f750d2a762984be098b786f285930a6a468ce7` |
| `opensource/aspose-email-net/SampleOstFile.ost` | `https://raw.githubusercontent.com/aspose-email/Aspose.Email-for-.NET/master/Examples/Data/MAPI/SampleOstFile.ost` | yes | MIT | 4,080,640 | `5ff8bc133935a03fad8241f271a604e1cc41e36640d6538d6bcc9bd39e6d9866` |
| `opensource/aspose-email-net/PersonalStorageFile.ost` | `…/Examples/Data/MAPI/PersonalStorageFile.ost` | yes | MIT | 271,360 | `4e3ac7dc5f318aba74b9369a38dce45a4234cf7b19e30c2bd9ef2926047f9f54` |
| `opensource/aspose-email-net/test.ost` | `…/Examples/Data/MAPI/test.ost` | yes | MIT | 271,360 | `ca2f8211608f3059064f00f5296e12912906a764e66996b728545feb54d68f38` |
| `opensource/aspose-email-net/SampleNSF.nsf` | `https://raw.githubusercontent.com/aspose-email/Aspose.Email-for-.NET/master/Examples/Data/Email/SampleNSF.nsf` (identical: Java repo `…/email/SampleNSF.nsf`) | yes | MIT | 47,448,064 | `0d71b76912ed8f448394ea9d2f77d93d5e2dc43465425f3b62b677f67340c03b` |
| `opensource/aspose-email-net/ExampleMbox.mbox` | `…/Examples/Data/MBOX/ExampleMbox.mbox` | yes | MIT | 276,938 | `b3b707a0635591747a46cd1898ba0d22d6863988b3e7e5bfc4fa91e1ff95a870` |
| `opensource/java-libpst/example-2013.ost` | `https://raw.githubusercontent.com/rjohnsondev/java-libpst/master/src/test/resources/example-2013.ost` | yes | Apache-2.0 / LGPL-3.0 (dual, `LICENSE.APACHE-2.0.txt` + `LICENSE.LGPL.txt`) | 16,818,176 | `b18ff390d0c22273029ee580ab6025976af69a4f84e276d1b1c01a988650853d` |
| `opensource/olmreader/outlook_example.olm` | `https://raw.githubusercontent.com/teverett/OLMReader/master/src/test/resources/Outlook16/outlook_example.olm` | yes | BSD-2-Clause (Tom Everett, 2016) | 1,404,748 | `cb8e3a70c70ca7f5b758fbee63278df0f188361ee987918a405c226286cf685c` |
| `opensource/olmreader/bill_rapp.olm` | `…/Outlook16/bill_rapp.olm` | yes | BSD-2-Clause | 5,781,944 | `344c0f81165b8b082b5715564d9145c1a35985e308438d33c95e3c43f2e8e814` |
| `opensource/tika-mail/testEMLX_multipart_html.emlx` | Tika mail-module test-documents (URL pattern above) | yes | Apache-2.0 | 3,261 | `bd7a97987ae26c7c5d6de5761d9d0ddfa3729894fa535b3efaba8968eab311d5` |
| `opensource/tika-mail/testEMLX_single_part_html.emlx` | same | yes | Apache-2.0 | 811 | `a745a84c241bb86038f6f280a8b73fbcfd55c751b7e3fdb723b04c3260319bea` |
| `opensource/tika-mail/testMBOX_complex.mbox` | same | yes | Apache-2.0 | 8,223 | `e5e46325c81c074b70338f217e8ce4e8ecb20c5a75a26d0069374b211ec85b7e` |
| `opensource/tika-mail/testMBOX_lengthy_x-headers.mbox` | same | yes | Apache-2.0 | 601 | `ef57bc3756f8d17ba8c87f15118516edcf869f17fe1a31a4249cb1dce52490f2` |
| `opensource/tika-mail/complex.mbox` | same | yes | Apache-2.0 | 14,022 | `c07ad5e7af40a6dcc2b8f96c65cd55455748cc19f24ed7e2fd32ac6340f3b2cf` |
| `opensource/tika-mail/single_mail.mbox` | same | yes | Apache-2.0 | 1,191 | `651b4e66624e0d558c9335f9433dc1515e6fa81c2aea1bba7549345601fd3b7e` |

In the repository (permissive licence AND under 2 MB): `Fixtures/opensource/aspose-email-net/SampleOLM.olm`,
`Fixtures/opensource/olmreader/outlook_example.olm`, `Fixtures/opensource/tika-mail/*` — see
`Fixtures/opensource/MANIFEST.md`. Everything larger (both OSTs, `bill_rapp.olm`, the NSF) stays in the
fixture root only. Microsoft's OFT (`public-pack/`) is never copied into Git.

## Not obtained

| Fixture | Why |
|---|---|
| Native Outlook for Mac OLM with "one mail record with two exact attachments/CID; upstream also records a contact and appointment" | This describes the owner's own export in pack 1, which has not arrived. The public native export `outlook_example.olm` (Outlook 16) was obtained instead and carries 7 mail records / 9 attachments and 5 contacts, 2 groups, 8 appointments, 5 tasks, 1 note — mail and non-mail are accounted separately in `RealMailStoreFixtureTests`. |
| Native OLM + Apple Mail MBOX + derived EML of the same message | Owner-bound: the three representations of one message exist only in the owner's pack. Apple Mail `.emlx` and generic MBOX samples from Tika were obtained, but they are not the same message and are not presented as that set. Listed as `pending` in `ExternalFixtures.required`, so the release preflight fails until it is supplied. |
| S/MIME fixtures | Owner-bound (pack 1) until 2026-11-09; now the synthetic `owner-pack/smime/` set above (owner permission 2026-11-09), files + assertions in place, no longer `pending`. |

## Independent inventories used by the tests

- OLM: the test extracts the archive with `/usr/bin/ditto -x -k`, walks `com.microsoft.__Messages/**/message_*.xml`
  with its own `XMLParser` delegate (not the production reader), resolves each `OPFAttachmentURL` to the
  extracted member and hashes its bytes. Observed: SampleOLM.olm 22 mail records / 38 attachment occurrences
  (24 with Content-ID) / 3 contacts; outlook_example.olm 7 / 9 / 5 contacts, 2 groups, 8 appointments, 5 tasks, 1 note.
- OST: `readpst` (libpst, Homebrew `/opt/homebrew/bin/readpst`) in `-D -e` and `-D -S` modes, recorded as
  `Fixtures/real/sampleost-readpst-inventory.json` and `Fixtures/real/example2013-readpst-inventory.json`.
  SampleOstFile.ost: 92 items = 87 mail + 5 calendar; 36 attachment payload files (RTF bodies excluded).
  The directive's "39 attachment payloads" is libpff's figure; the difference to readpst's 36 is reported
  by the test, not hidden. example-2013.ost (`wVer` 36): 3 mail items (2 Inbox, 1 Sent Items) plus one
  empty root item readpst writes as `16.eml` (no subject, no Message-ID). readpst reads the 4 KiB-page
  file, so libpst's geometry agrees with `PSTPageGeometry.fourK` on a real file.
- NSF: no independent Notes reader is on this Mac. The parser's own result is recorded; an inventory from
  an independent reader is still needed before any fidelity claim.

## What the real files found in the readers (fixed the same day, each with a failing-then-passing test)

| Reader | Found on | Defect | Fix |
|---|---|---|---|
| `OLMParser` | both OLMs | read state written as `OPFMessageGetIsRead` "1E0"/"0E0" — every message read as unread | boolean parsed from "1"/"true"/"1E0" |
| `OLMParser` | native OLM | flag element is `OPFMessageCopyGetFlagStatus` | listened for; non-zero = flagged |
| `OLMParser` | native OLM | categories are `OPFMessageCopyCategoryList/category@OPFCategoryCopyName` + a nested `OPFMessageCopyPrimaryCategory/OPFCategoryCopyName` | both read, deduplicated, as tags |
| `OLMParser` | native OLM | priority 2 (high) / 4 (low) dropped | 1/2/4/5 pass through as X-Priority |
| `OLMParser` | both | attachment sizes written as "7.39E3" parsed as 0 | float parse |
| `OLMParser` | both | non-mail trees are `Local/Address Book/**/Contacts.xml`, `Groups.xml`, `Calendar/Calendar.xml`, `Tasks/Tasks.xml`, `Notes/Notes.xml` (not `com.microsoft.__Contacts` …) and were counted per FILE under "other"; `Categories.xml` counted as an object | counted per record under the right receipt category; groups separately; colour table excluded |
| `OLMParser` | Aspose OLM | received time not preserved when a sent time exists | `X-Mailin-Received-Time` header |
| MIME extractor | Aspose OLM | a `message/rfc822` attachment lost its own name ("attached.eml") | the part's own filename wins; "attached.eml" only when nameless |
| `PSTSpecReader` | example-2013.ost | 4 KiB-page OST blocks are zlib-compressed (BBTENTRY `cb, cbInflated`); the reader kept the raw deflate bytes — 3 messages without properties, folders without names | `PSTBlockInflate`; `Block.cbInflated` read from the 4 KiB entry; inflate before decode (libpst's order) |
| `PSTSpecReader` | SampleOstFile.ost | OLE attachments (method 6) stored as their 8-byte PtypObject cell | subnode stream read (all 36 readpst payloads byte-identical) |
| `NSFParser` | SampleNSF.nsf | gave up after 100,000 bytes without a record — a real database's first megabytes are design notes | whole file scanned; result still 0 (the reader does not parse the ODS layout — recorded, not claimed) |

Real-file facts recorded in `PSTPageGeometry.swift`: Outlook 2013 puts the DList at 0x21000 and the first AMap at
0x22000 (`PSTWriterLayout.ost4K` assumed 0x4000/0x5000 — writer-only constants, the reader takes positions from the header).
