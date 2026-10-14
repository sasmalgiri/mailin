# PST export (`PSTSpecWriter`, switch "Outlook PST writer (MS-PST)") — validation record

Status: **not verified in Outlook.** SCANPST and Outlook are not available in the development
environment; every Outlook-side result below comes from logs the owner ran on Windows. The writer
stays a preview switch, and exports use the earlier writer by default, until a fresh, unrepaired file
passes SCANPST with nothing to repair and opens in Outlook.

Source: `Packages/ArchiveCore/Sources/ArchiveCore/PSTSpecWriter.swift`.
Tests: `Packages/ArchiveCore/Tests/ArchiveCoreTests/PSTSpecWriterTests.swift`.
Independent checks (run on the Mac, not shipped): `Scripts/pstvalidate.py` (NDB), `Scripts/pstltp.py`
(LTP), `Scripts/rowscan.py` and `Scripts/pstrowdiag.py` (contents rows), `Scripts/validate_fixtures.py`
(libpff + libpst + `Scripts/pstdump.py` against regenerated expected values).

## Defects found from SCANPST logs, and their causes

| Log | SCANPST finding | Root cause | Fix (PSTSpecWriter.swift) |
|---|---|---|---|
| v2 | Mandatory spam search folder missing (Outlook refused the file) | [MS-PST] 2.7.1 node 0x2223 not written | spam folder + 0x2226/0x2227/0x2230 written in `finalize()` (≈ line 1037) |
| v2 | 990/1000 contents rows ≠ message | row cells Outlook never fills (PidTagMessageToMe/CcMe), stored DisplayCc/DisplayBcc (computed, [MS-PST] 2.5.2.3) | dropped (≈ line 854) |
| v3 | Recipient TCs rejected ("keys overlap", 12 "missing" columns) | recipient row IDs started at 0 | unique non-zero IDs + one-off EntryID (`nextRecipientRowID`, `oneOffEntryID` ≈ line 217) |
| v3 | Root hierarchy TC invalid | spam row appended after higher row IDs; row index is a sorted B-tree | rows must ascend; enforced in `TableBuilder.addRow` (≈ line 656) |
| v3 | "Middle page not full" | heap and row-matrix blocks before the last not padded to 8,176 bytes | `closeBlock` (≈ line 512), `flushRows(padToBlock:)` (≈ line 695) |
| v3 | PR_ATTACH_SIZE invalid | stored file size, not the sum of the attachment's property values | `attachmentSize` (≈ line 202); fits 78/80 real attachments |
| v3 | Missing template 0x6F8 | templates 0x62B/0x64C/0x6D7/0x6F8 not written | copied from an Outlook 2010 file (`Templates`) |
| v4 | NID high-water mark type 31: read 400, calculated 401 | rgnid[] set by hand; must be the last nidIndex allocated per type ([MS-PST] 2.2.2.6), start-clamped — rule checked on 12 Outlook files | computed from every NID allocated (`noteNID`, `rgnid` ≈ line 231); test recomputes it from the file |
| v4 | Receive folder table missing default message class | 0x62B written without rows | Outlook's four rows: "" / IPM / Report.IPM → Inbox, IPC → root (≈ line 987) |
| v4 | SAL missing entry (nid=2223) | 0x201 empty | lists the spam search folder (≈ line 972) |
| v4 | (no SCANPST line) | PidTagMessageStatus and PidTagHasAttachments stored on messages; computed by the store, never stored by Outlook | not stored (≈ line 845) |

## Open after v4

- **Contents-table rows (800 in 0x8082, 200 in 0x80A2).** `pstrowdiag.py` finds every column
  descriptor valid, the row index, row matrix and NBT consistent, and all 13 copied columns equal to the
  message on all 1,000 rows. Decoding cannot show what SCANPST compares. Next evidence: the SCANPST
  logs for `mailin-outlook-test-v5.pst` and `…-v5-rowver0.pst` (the only difference is
  PidTagLtpRowVer, which changed between v2, where 10 rows passed, and v4, where none did), and a
  **SCANPST-repaired copy**, whose diff against the original shows Microsoft's correction.
- **Search folder `EC1` missing update queue.** 0xEC1 (an internal-type NID) occurs nowhere in the
  generated file (byte search over all blocks); it is created by SCANPST during repair. Expected to
  clear with the SAL fix; to be confirmed by the v5 log.
- **"HMP not found – creating".** No structure of that name exists in [MS-PST]; not implemented
  (no invented node). Reported by users on Outlook-created files too.
- **"Deleting SDO".** [MS-PST] 2.4.8 (special internal NIDs): the search domain object 0x261 is "the
  global list of all Folder objects that are referenced by any Folder object's Search Criteria". The
  only search criteria object written (0x2227) references no folder, so there is nothing to list; no SDO
  is written. SCANPST's deletion is taken as maintenance, not a defect — to be confirmed.
