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
| v2 | 990/1000 contents rows ≠ message | row cells Outlook never fills (PidTagMessageToMe/CcMe), stored DisplayCc/DisplayBcc (computed, [MS-PST] 2.5.2.3) | dropped (≈ line 854) — DisplayCc/Bcc part reversed in v6, see v5 row |
| v3 | Recipient TCs rejected ("keys overlap", 12 "missing" columns) | recipient row IDs started at 0 | unique non-zero IDs + one-off EntryID (`nextRecipientRowID`, `oneOffEntryID` ≈ line 217) |
| v3 | Root hierarchy TC invalid | spam row appended after higher row IDs; row index is a sorted B-tree | rows must ascend; enforced in `TableBuilder.addRow` (≈ line 656) |
| v3 | "Middle page not full" | heap and row-matrix blocks before the last not padded to 8,176 bytes | `closeBlock` (≈ line 512), `flushRows(padToBlock:)` (≈ line 695) |
| v3 | PR_ATTACH_SIZE invalid | stored file size, not the sum of the attachment's property values | `attachmentSize` (≈ line 202); fits 78/80 real attachments |
| v3 | Missing template 0x6F8 | templates 0x62B/0x64C/0x6D7/0x6F8 not written | copied from an Outlook 2010 file (`Templates`) |
| v4 | NID high-water mark type 31: read 400, calculated 401 | rgnid[] set by hand; must be the last nidIndex allocated per type ([MS-PST] 2.2.2.6), start-clamped — rule checked on 12 Outlook files | computed from every NID allocated (`noteNID`, `rgnid` ≈ line 231); test recomputes it from the file |
| v4 | Receive folder table missing default message class | 0x62B written without rows | Outlook's four rows: "" / IPM / Report.IPM → Inbox, IPC → root (≈ line 987) |
| v4 | SAL missing entry (nid=2223) | 0x201 empty | lists the spam search folder (≈ line 972) |
| v4 | (no SCANPST line) | PidTagMessageStatus and PidTagHasAttachments stored on messages; computed by the store, never stored by Outlook | not stored (≈ line 845) |
| v5 | NID high-water mark, receive folder class, SAL 2223 | — | no longer reported (v4 fixes confirmed) |
| v5 | Row ≠ message on all 1,000 rows (both v5 files; row version ruled out: identical logs) | Decoded diff of the original against SCANPST's repaired copy (`mailin-outlook-test-v51.pst`): SCANPST rewrote **PidTagMessageSize on all 1,000 messages** and **added DisplayCc (334) / DisplayBcc (143)**, DisplayCc also to the rows. The size SCANPST computes = bytes of the message node's data blocks (property context + every subnode, nested; XBLOCK/SLBLOCK excluded): exact on 1,000/1,000 repaired messages and on all 158 messages of the three newest Digital Corpora Outlook files (bill.jobs ×2, johnblair68); the nine older ones store other values (an older Outlook's rule, not followed). mailin stored the raw MIME length. The v3 removal of DisplayCc/Bcc was wrong (the Outlook files compared then had no Cc). | `MessageBuild.write` (≈ line 880): size measured from the bytes written (`leafBytesWritten`, `propertyContextDataBytes`), shared by message and row; DisplayCc/Bcc stored when present, DisplayCc in the row. Reader takes To/Cc/Bcc from the recipient table (addresses) before the name-only display lines (`PSTSpecReader` ≈ line 499). |
| v6 | All 1,000 row mismatches gone. Left: EC1 update queue, HMP not found, Deleting SDO | Repair `mailin-outlook-test-v61.pst` (not opened in Outlook) made exactly three changes: removed the empty 0x261; added 0xC01 "HMP" (heap client 0x9C → BTH of 16-byte GUID → NID, one per message and normal folder; not in [MS-PST]); added an empty 0xEC1 (not in [MS-PST], in none of 12 Outlook files) | v7: no SDO; 0xC01 written as Outlook 2010 writes it, empty, byte-identical to bill.jobs/johnblair68 (135 / 18 messages, empty HMP); 0xEC1 **not** written (placeholder with no definition) — only in a labelled diagnostic file for SCANPST (`diagnosticEmptyNodes`, test-only) |
| v7 | Export: one line left, `!!Search folder (nid=EC1) missing update queue` (HMP and SDO lines gone: the empty Outlook-2010 HMP is accepted). Diagnostic file (export + empty 0xEC1): **no `!!` or `??` line at all** | Both repaired copies (v71, diagnostic-ec11; neither opened in Outlook) differ from the originals in the same six nodes even where nothing was reported: store gains PidTagReplVersionhistory 0x0E34 (count 1, GUID, counter 1); every folder and message row gains PidTagReplItemid 0x0E30 (GUID = the HMP key for that NID), ReplChangenum 0x0E33, ReplVersionhistory 0x0E34 and a new row version; HMP filled (1,005 GUID → NID). The newest Outlook-written files (bill.jobs ×2, johnblair68) have no Repl cells in rows and an empty HMP, as mailin writes; all ten 2009+ Outlook files have 0x0E34 on the store, mailin's store does not | Pending owner: (a) adopt the empty 0xEC1 in exports (clears SCANPST's last finding; no published definition); (b) what SCANPST's dialog said for the diagnostic file ("no errors" vs "minor inconsistencies"), which decides whether store 0x0E34 is next |
Check of the v6 writer against Microsoft's corrections (`vs_repaired.py`, same content, matched by subject):
size equal on 990/1,000, DisplayCc and DisplayBcc equal on 1,000/1,000. The 10 others are Inbox
messages Outlook changed after the repair (it added PidTagPreview 0x3FD9, PidTagUserEntryId 0x6619
and a named property when showing them), so SCANPST's original value is not recoverable for them;
their size still follows the same rule.

Not changed, on evidence: the repaired contents tables have extra columns (0x3602 in both folders;
sender, preview, flag and two named-property columns in Inbox). They appear identically in the
rowver0 repair, which Outlook never previewed, and include named properties SCANPST does not create,
so they are Outlook's view columns (tables gain columns as views ask for them); 178 of 214 contents
tables in Outlook-written files lack 0x3602. To be confirmed by the v6 log.

## Open after v5

- **Search folder `EC1` missing update queue.** 0xEC1 (an internal-type NID) occurs nowhere in the
  generated file (byte search over all blocks); it is created by SCANPST during repair. Still in
  the v5 log after the SAL fix; no published structure ties it to anything mailin writes. The v5 repair
  added internal nodes 0xC01, 0xE01, 0xE41, 0xEC1, 0xEE1, 0xF01, 0xF21 (undocumented); of 12
  Outlook-written files, 0xC01 is in 10, 0xE01/0xE41 in 3, the other four in none. Not written.
- **"Deleting SDO".** v6 wrote an empty SDO; SCANPST deleted it. v7 writes none (no criteria reference a folder).
- **"HMP not found – creating".** v7 writes 0xC01 empty, exactly as Outlook 2010 does. Whether SCANPST accepts an empty HMP with 1,000 messages is for the v7 log to show; if not, the next evidence is a second SCANPST pass over the repaired v61.
- **EC1.** Open. Diagnostic file `mailin-outlook-test-v7-diagnostic-ec1.pst` tests whether the empty node alone clears it; adopting it in exports is the owner's decision (it has no published definition).
