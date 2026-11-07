# Open-source fixtures in the package test tree (added 2026-11-07)

Real files from public repositories, copied here only when the licence is permissive AND the file is
under 2 MB. Everything larger, and all Microsoft material, lives in the external fixture root
(`$MAILIN_FIXTURE_ROOT`, default `~/Downloads/Mail/Fixtures`) — see `../FIXTURE_ACQUISITION_2026-11-07.md`
for every URL tried, licence, size and SHA-256.

| Folder | File | Origin | Licence | SHA-256 |
|---|---|---|---|---|
| `aspose-email-net/` | `SampleOLM.olm` | https://github.com/aspose-email/Aspose.Email-for-.NET `Examples/Data/MAPI/SampleOLM.olm` (`master`, 2026-11-07) | MIT (Aspose Pty Ltd) | `a3aa54a01157618b1a45949f25f750d2a762984be098b786f285930a6a468ce7` |
| `olmreader/` | `outlook_example.olm` | https://github.com/teverett/OLMReader `src/test/resources/Outlook16/outlook_example.olm` (`master`, 2026-11-07) — a native Outlook 16 for Mac export | BSD-2-Clause (Tom Everett, 2016) | `cb8e3a70c70ca7f5b758fbee63278df0f188361ee987918a405c226286cf685c` |
| `tika-mail/` | `testEMLX_multipart_html.emlx`, `testEMLX_single_part_html.emlx`, `testMBOX_complex.mbox`, `testMBOX_lengthy_x-headers.mbox`, `complex.mbox`, `single_mail.mbox` | https://github.com/apache/tika `tika-parsers/tika-parsers-standard/tika-parsers-standard-modules/tika-parser-mail-module/src/test/resources/test-documents/` (`main`, 2026-11-07) | Apache-2.0 | see the acquisition note |

What is deliberately NOT here: `SampleOstFile.ost` (4 MB), `example-2013.ost` (16 MB), `SampleNSF.nsf` (47 MB),
`bill_rapp.olm` (5.8 MB) — external root only; Microsoft's OFT — never in Git.

`RealMailStoreFixtureTests` reads the external copies through `ExternalFixtures.require(_:)` (SHA256SUMS-verified)
and skips, naming the file, when a copy is absent; the in-repo copies above are for the two OLM anchors so
the OLM reader tests also run on a Mac without the fixture root.
