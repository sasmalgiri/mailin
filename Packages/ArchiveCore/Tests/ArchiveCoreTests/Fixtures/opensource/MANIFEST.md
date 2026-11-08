# Open-source fixtures for the ArchiveCore package tests (downloaded 2026-11-07)

Real files written by Publisher, Visio, Project, Access and OneNote, taken from the test corpora of
three open-source projects. They are test data and are used here only to verify mailin's readers
(directive 2026-11-07 §6 "Other business formats"). Read by path from `#filePath`, not bundled.

| Folder | Source | Revision | Licence |
|---|---|---|---|
| `tika/` | https://github.com/apache/tika — `tika-parsers/tika-parsers-standard/tika-parsers-standard-modules/tika-parser-microsoft-module/src/test/resources/test-documents/` | `main` on 2026-11-07 | Apache-2.0 |
| `poi/` | https://github.com/apache/poi — `test-data/publisher/` (Publisher files and `Sample.txt`, the author's record of `Sample.pub`'s text), `test-data/diagram/` (binary Visio files, including the malformed `NegativeChunkLength.vsd` and `ShortChunk1.vsd`) | `trunk` on 2026-11-07 | Apache-2.0 |
| `mpxj/` | https://github.com/joniles/mpxj — `junit/data/` (Microsoft Project .mpp files: MPP8 `DurationTest8.mpp`, MPP9 `SubprojectA-9.mpp`, MPP12 `mpp12columns.mpp`, MPP14 `ResourceIdAndUniqueId-project2013-mpp14.mpp`) | `master` on 2026-11-07 | LGPL-2.1 (test data) |

## Files

| File | Written by | What the tests assert (from the upstream tests where they exist) |
|---|---|---|
| `tika/testPUBLISHER.pub` | Publisher (author Nick Burch) | text contains `0123456789` and `abcdef` (Tika `PublisherParserTest`) |
| `poi/Sample.pub`, `poi/Sample.txt` | Publisher | every line of `Sample.txt`; hyperlinks `http://poi.apache.org/`, `mailto:dev@poi.apache.org` |
| `poi/LinkAt10.pub` | Publisher | one hyperlink |
| `tika/testVISIO.vsd` | Visio 2003 (author Hogwarts) | `Some random text, on a page` (Tika `VisioParserTest`) |
| `poi/44501.vsd` (Visio 2000), `poi/44594.vsd`, `poi/SimpleMacro.vsd` (Visio 2003) | Visio | `Penible`, `Nouveau farine`; `Drag the side handles to change the width of the text block.`; `This is a macro vector graphics drawing` (no VBA storage despite the name) |
| `poi/NegativeChunkLength.vsd`, `poi/ShortChunk1.vsd` | Visio 2003, damaged | POI regression files: text still read (`Feldbreite einstellen, um Absatzbreite festzulegen.`, `Betätigung des`), the over-long chunk recorded by position, no trap |
| `tika/testPROJECT2003.mpp`, `tika/testPROJECT2007.mpp` | Project 2003 (MPP9) / 2007 (MPP12), author Nevin Nollop | title `The quick brown fox jumps over the lazy dog`, subject `Gym class featuring a brown fox and lazy dog`, keywords `Pangram, fox, dog`, comments `Comment Vulpes vulpes comment`, company `CompanyA`, manager `Mr Burns`, category `Category1` (Tika `ProjectParserTest`); tasks `Aquire fox` / `Obtain Dog` / `Fox does his jump`, resources `Fox` / `Dog` (Tika reads no body text from these) |
| `mpxj/mpp12columns.mpp` (MPP12), `mpxj/ResourceIdAndUniqueId-project2013-mpp14.mpp` (MPP14), `mpxj/SubprojectA-9.mpp` (saved as MPP14) | Project 2007 / 2013 | `Task One` + `Resource One`; summary task `ResourceIdAndUniqueId`, resources `Resource One/Two/Three` with IDs 11–13; `Subproject Task A/A1/A2`, author `Wade Golden` |
| `mpxj/legacy/readpassword9.mpp`, `bothpassword9.mpp`, `writepassword9.mpp` (kept flat in `mpxj/`) | Project 2003 with a read / both / write-reservation password | read password → reported locked, nothing read; write reservation → blocks decoded with the file's code (`Task One`) and said so |
| `mpxj/DurationTest8.mpp` | Project 98 (MPP8) | recognised; properties (`Jon Iles`) read; tasks honestly reported as not read |
| `tika/testAccess_V1997.mdb` | Access 97 (Jet 3, 2 KiB pages) | `hijklmnop` (Tika `JackcessParserTest`); the whole row `abcdefg / hijklmnop / 2 / 222 / 333333333 / 444.555 / 1974-09-21 / 3.5 / Yes` and the empty Table2–4 |
| `tika/testACCESS.mdb` | Access 2000 (Jet 4) | four user tables (`Titles`, `Tracks`, `Menus`, `Batch`) listed, each without rows |
| `tika/testAccess2.accdb`, `tika/testAccess2_2000.mdb`, `tika/testAccess2_2002-2003.mdb` | Access 2007 (ACE) / 2000 / 2002–2003 (Jet 4) — the same database saved three ways | `ShortTextField=the quick`, `DateField=2015-06-24`, memo `over the <strong>bold </strong><em>italic</em> dog`, `普林斯顿大学`, `PlainTextMemo=red and brown`, `CurrencyField=6.23`, `Table2` `LongDateTime=2015-06-29`; `Table1.OLEObject` listed as not text (Tika `JackcessParserTest`) |
| `tika/testAccess2_encrypted.accdb` | Access 2010 (password `tika`) | reported locked, nothing read |
| `tika/testOneNote1.one`, `testOneNote2.one`, `testOneNote3.one`, `testOneNote4.one` | OneNote 2013 (MS-ONESTORE) | Doc2: `wow this is neat`, `neat info about totally killin it bro`, `Section1TextArea1`, `Section1HeaderTitle`, `Section1TextArea2`; Doc3: `awesome information about sports or some crap like that.`, `Quit doing horrible things to me. Dang you.`, `Section2*`; Doc4: `way too much information about poptarts to handle.`, `Section3*`; no `Calibri` or garbage UTF-16 in any (Tika `OneNoteParserTest`) |
| `tika/testOneNote2016.one` | OneNote 2016 | `So good`, `This is one note 2016` |
| `tika/test-tika-4303-Chinese-notes.one` | OneNote 2016 | `中文标题` (TIKA-4303) |
| `tika/testOneNoteFromOffice365.one`, `testOneNoteFromOffice365-2.one`, `testOneNoteTablesLists.one` | Office 365 (FSSHTTPB packaging) | `Section1Page1Content`, `Section1Page2Content`; table cells `Table cell 1a` … `Table cell 4b`, list items `Bullet 2`, `Indented bullet`, `Number 2`, `Letter a`, `Numeral I`, `Outdented number` |
| `tika/testOneNote2007OrEarlier.one` | OneNote 2007 (packaging GUID, no readable revision store) | the long "One note is the application…" paragraph and `Correlation between Outlook and OneNote` |
| `tika/testOneNoteEmbeddedWordDoc.one` | OneNote 2013 | the embedded Word file is listed as not text |
| `tika/testOneNote.one`, `tika/testOneNote-fuzz1..3.one` | OneNote 2010; fuzzer regressions | fuzz files must not trap; fuzz1/fuzz2 report their damage |
| `../derived/testOneNote.onepkg` (+ `make_onepkg.py`) | built here from `testOneNote2.one` + `testOneNote3.one` | cabinet with one MSZIP folder in 15 blocks (byte-identical members), a stored `.onetoc2` stub, an LZX folder named and not opened |

Nothing from an owner-private pack is in this folder.

---

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

---

# Excel number-format oracles (added 2026-11-09)

From https://github.com/apache/poi `test-data/spreadsheet/` (`trunk`, 2026-11-09), Apache-2.0, each under 60 KB,
in `poi/`. Read by `ExcelNumberFormatTests`. In the `*FormatTests.xlsx` workbooks, sheet 2 column A is
`=TEXT(C, B)` with the text Excel cached when it saved the file (a few rows, e.g. the negative half of
FormatConditionTests, hold the expected text typed by POI's authors), B the format code, C the value, D a
category. All were saved by Mac Excel in the 1904 date system. POI's `CellFormat` tests use them the same way.

| File | SHA-256 | What is asserted |
|---|---|---|
| `poi/NumberFormatTests.xlsx` | `a11d437ee538abe36d630a4795dd30d5823a68dce02a404a45e085dd49c4435d` | every one of 300+ rows (placeholders, escapes, thousands, scaling, percent, `?` spacing, fractions with literals, improper fractions) renders to column A |
| `poi/GeneralFormatTests.xlsx` | `607ff06ff0295d0920d81b27e09b91e86301b9f3862d1d22b093f8f8c5a4de28` | every numeric row of General (11-character rule, `1E+11`, `1E-10`) |
| `poi/DateFormatTests.xlsx` | `16445dc0deba00671ee4315015a970d415ce9886da59c974532d946e99276c66` | every row: d/m/y in both cases, ddd/dddd, mmm/mmmm, yyy, h:m:s, AM/PM, a/p, fractions of a second, 1904 serials |
| `poi/DateFormatNumberTests.xlsx` | `d18aade6ad10435baa4be3ac1c4ba4c15e48248bc24b91926920f3dec0aca033` | every row: seconds and `.0`/`.00`/`.000` rounded at the shown precision |
| `poi/ElapsedFormatTests.xlsx` | `c3e574f098855b4d28e618353337c10941fc01d8e6c320c46a79731d5425c7ca` | every row: `[h]`, `[m]`, `[s]`, `[hh]`, mixed with plain units, negative elapsed values |
| `poi/FormatConditionTests.xlsx` | `96afa10c8f1f633fc2eaebf21a0883c96a8be2cc5f38fc8c2e826b5d9c140d4f` | every row: `[<10]`, `[>=-10]`, `[<>10]` … with spaces, General fallback |
| `poi/TextFormatTests.xlsx` | `c224c784e77f321c59c90f6d93380ff74a0e0013f0346e4b2cdf0a5ff5e3840b` | the six text rows whose code has `@`; the three literal-only codes are where `TEXT()` differs from a cell (a cell shows text as typed without a text section) |
| `poi/Formatting.xlsx` | `5a0aa7c36c53b22cd26e3eeb2ee49bf16f7e4101aafa8b1503a0778f4010ddbc` | through the XLSX reader: 24 November 2006 (serial 39045) in built-in 14 (`11/24/2006`, en-US) and five custom date codes; 10.52 in General, `0.000`, `0.0`, `"£"#,##0.00` |

`NumberFormatApproxTests.xlsx` (exotic `e-` exponent layouts with literals inside the mantissa) was looked at
and not added: those layouts are not rendered.
