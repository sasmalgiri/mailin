# mailin: missing compatibility fixtures

Prepared 7 November 2026. This pack supplies the three fixture categories listed as owner-only in mailin's tracker: an Outlook OFT, encrypted archives, and a Word document with retained tracked changes.

**These are available test inputs, not a claim that mailin has passed them.** The public originals were downloaded and inspected. Archive passwords were checked with independent readers. The macOS app was not run here.

## Start with these three files

| Need | File | Provenance / password |
| --- | --- | --- |
| Real Outlook template | `01_outlook/Set_Up_Mobile_Thru_Admin.oft` | Official Microsoft Download Center template for Outlook. No password. |
| Archive actually made by 7-Zip | `02_archives/7zip_generated/7zip_AES256.zip` | Created for this handoff with the official 7-Zip 26.05 binary. Password: `mailin-fixture-2026`. |
| Word-authored tracked changes | `03_word/W05_tracked_retained.docx` | Public Word-native research corpus. Two insertions and one deletion remain pending. No password. |

The package also contains public libarchive encrypted ZIP/7z regression fixtures, two additional archives produced with official 7-Zip, three Word comparison controls, and seven ready-to-import EML wrappers. The wrappers are synthetic transport envelopes: they preserve the attachment bytes unchanged and are not represented as Outlook-created mail.

## 1. Outlook OFT

Source page: https://www.microsoft.com/en-us/download/details.aspx?id=44066

Direct original: https://download.microsoft.com/download/0/5/f/05f327a1-e5b6-41df-b8d0-2c698b5d6b99/Set_Up_Mobile_Thru_Admin.oft

- Original size: 960,512 bytes.
- SHA-256: `ca98181d4b7a77d5cc7cd6dc941003dde8128ec48a6ca1c0cb93d27a7c0dbe1c`.
- Compound-file structure and MAPI properties are present. Message class is `IPM.Note`.
- Expected subject: `Set up Office on all your devices`.
- Contains 22 image attachment storages with filenames, MIME types, content IDs and bytes. Full attachment hashes are in `expected_results.json`.
- The official download establishes an independent Outlook template source. The exact producing Outlook build is not published; do not invent one.

**Mailin test (COMP-04):** import the OFT directly and through its EML wrapper. Confirm the subject, body and all 22 image payloads are preserved, including CID relationships. Exercise search, preview and export; compare original and exported attachment digests. This fixture covers an ANSI MAPI template with rich embedded images, not every possible OFT variant. Do not send this email as part of the test or load its remote resources.

## 2. Encrypted archives

### Public libarchive fixtures

Source commit: https://github.com/libarchive/libarchive/tree/eb57ffefe20e98eb7ba05829ee1c23b90e589a71

| File under `02_archives/public/` | Password | Expected content |
| --- | --- | --- |
| `test_read_format_zip_winzip_aes128.zip` | `password` | One encrypted `README`, 6,818 bytes; AES-128. |
| `test_read_format_zip_winzip_aes256.zip` | `password` | Same README; AES-256 with compression. |
| `test_read_format_zip_winzip_aes256_stored.zip` | `password` | Same README; AES-256 with stored data. |
| `test_read_format_7zip_encryption.7z` | `12345678` | `bar.txt`, four bytes: `foo` followed by newline; data encrypted. |
| `test_read_format_7zip_encryption_header.7z` | `12345678` | Same file; headers and data encrypted. |
| `test_read_format_7zip_encryption_partially.7z` | `12345678` | `bar_unencrypted.txt` and `bar_encrypted.txt`; four bytes each. |

These files are distributed upstream as uuencoded `.uu` files. This pack decodes that transport encoding to recover the original binary bytes; it does not recreate/recompress the archives. `download_manifest.json` records both the source download hash and the decoded binary hash.

Upstream tests document the passwords and expected properties:

- https://github.com/libarchive/libarchive/blob/eb57ffefe20e98eb7ba05829ee1c23b90e589a71/libarchive/test/test_read_format_zip_winzip_aes.c
- https://github.com/libarchive/libarchive/blob/eb57ffefe20e98eb7ba05829ee1c23b90e589a71/libarchive/test/test_read_format_7zip_encryption_data.c
- https://github.com/libarchive/libarchive/blob/eb57ffefe20e98eb7ba05829ee1c23b90e589a71/libarchive/test/test_read_format_7zip_encryption_header.c
- https://github.com/libarchive/libarchive/blob/eb57ffefe20e98eb7ba05829ee1c23b90e589a71/libarchive/test/test_read_format_7zip_encryption_partially.c

**Provenance distinction:** WinZip AES names an encryption format. These source files establish public interoperability fixtures, but the original creating application/version was not established in this review. Use the following additional fixtures when the acceptance row specifically requires a recorded 7-Zip producer.

### Archives produced here by official 7-Zip

Files under `02_archives/7zip_generated/`:

- `7zip_AES256.zip`: ZIP with AES-256.
- `7zip_ZipCrypto.zip`: ZIP with traditional ZipCrypto.
- `7zip_AES256_header_encrypted.7z`: 7z with encrypted headers and data.

Password for all three: **`mailin-fixture-2026`**.

Each contains `README.txt` and `nested/W05_tracked_retained.docx`. The README includes the searchable marker `MAILIN-PROTECTED-CONTENT-20261107`. The nested DOCX is byte-identical to the public Word-authored sample. Plain inputs are included under `02_archives/7zip_inputs/`.

These three archives are newly generated for this request, not pre-existing online corpus files. They were created using official **7-Zip 26.05 for Linux x64**, independently of mailin's archive code. The downloaded tool's SHA-256 matched the digest reported by its GitHub release. The tool itself is not bundled.

- Official download listing: https://www.7-zip.org/download.html
- Tool release: https://github.com/ip7z/7zip/releases/tag/26.05
- Download SHA-256: `22cf82fcc6eb7474f1d5bb4f02c0f8ebd573a718089d6833dc30f8350a3b232e`.
- Exact creation commands and verification exits: `provenance/7zip/creation_and_tests.json`.

All nine archives passed `7zz t` with the correct password and failed with a deliberately wrong password. ZIP contents were also decrypted and hash-compared using pyzipper. The three public 7z files were additionally read using py7zr during inspection.

**Mailin test (COMP-13):** before unlocking, disclose locked/incomplete coverage. Try an incorrect password, cancel, then use the correct password. Check session-only versus stored indexing, app restart, child identities, nested DOCX revisions, search evidence and export hashes. For the mixed archive, keep the available plaintext file searchable while clearly reporting the encrypted child. A header-encrypted archive has unknown members until it is unlocked. Keep ZIP and 7z results separate; a ZIP pass does not prove 7z support.

## 3. Microsoft Word tracked changes

Source repository/commit: https://github.com/InterTechSA/docx-edit-trail-analyser/tree/a8aea6152926d5b8875104f81df9306fc61ebbb7

Direct retained-change file: https://raw.githubusercontent.com/InterTechSA/docx-edit-trail-analyser/a8aea6152926d5b8875104f81df9306fc61ebbb7/samples/word_native/W05_tracked_retained.docx

The upstream environment record identifies Word for Microsoft 365, Version 2608, Build 16.0.20326.20072, 64-bit, on Windows 11. Its ground-truth record describes editing with Track Changes enabled and records deviations from the original experimental instructions. Copies of those records are included under `provenance/word/`.

The downloaded DOCX was inspected directly: it contains two `w:ins` elements (`red` and a trailing space) and one `w:del` element (`brown `, including its trailing space). The source records a real Word editing session; this is not a DOCX generated here by inserting XML tags. Its application metadata also identifies Microsoft Office Word.

Four files are included:

| File | Purpose |
| --- | --- |
| `W01_baseline.docx` | Baseline text before tracked editing. |
| `W05_tracked_retained.docx` | Two insertions and one deletion retained. |
| `W06_tracked_accepted.docx` | Accepted-change control; no pending insertion/deletion elements. |
| `W07_tracked_rejected.docx` | Rejected-change control; no pending insertion/deletion elements. |

**Mailin test (COMP-08):** search inserted and deleted content separately under the declared revision policy. Label deleted text as deleted; do not present it as current body text. Check authors/dates, surrounding context, evidence locations, attachment opening and original-byte export. Run the accepted and rejected controls so stale revision text does not persist after reindexing. This sample establishes insertion/deletion coverage; moved text, formatting revisions and revisions in other document sections need their own cases.

## Verification and agent handoff

1. Extract this outer ZIP. It is not password protected.
2. Run `python3 verify_fixtures.py` from this folder. It checks all manifest hashes, DOCX revision structures and the byte identity of EML-wrapped attachments using only Python's standard library.
3. Import `04_import_ready_eml/` into a disposable mailin archive; also test direct OFT intake. The seven emails make the source files usable through the actual mail attachment pipeline.
4. Run the acceptance checks above through production code and the UI. Record exact app commit/build, platform, fixture hash, password mode, result and logs.
5. Update COMP-04, COMP-08 and COMP-13 from **fixture unavailable/owner-only** to **fixture acquired; execution pending**, then to passed only after the relevant test succeeds. Preserve failures as reproducible defects.

The S/MIME keychain-identity run and the three UI/design decisions are separate. A disposable development S/MIME identity can be created for that test; a production personal private key is not needed for sourcing these fixtures. This pack does not install identities or decide those UI choices.

## Source and reuse notes

- Word corpus: upstream MIT license included, with attribution.
- libarchive: upstream COPYING and the test sources with their notices included.
- Microsoft OFT: official Microsoft material supplied for this requested compatibility test. It is not labelled open source. Keep it out of the shipped app/public fixture redistribution unless the applicable Microsoft permission has been established; the official download link and hash support fetching it for tests.
- Newly created plaintext and wrapper code: may be used and modified for mailin testing. The nested Word file retains its upstream license. Generated archives are labelled as generated rather than public originals.

`expected_results.json` is the machine-readable oracle; `download_manifest.json` records source URLs, sizes and hashes; `SHA256SUMS` covers the delivered pack contents.
