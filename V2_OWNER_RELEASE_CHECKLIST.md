# V2 OWNER RELEASE CHECKLIST

Everything the agent could do is done (see V2_IMPLEMENTATION_COMPLETE.md).
These gates require you, a device, or the App Store account.

## A. Manual macOS UI smoke (against the exact candidate SHA)

- [ ] Launch fresh (new archive) and with an existing archive
- [ ] Import: mbox, eml, drag-drop, multi-file; cancel mid-import; relaunch → resume
- [ ] Unsupported file (.zip/.pdf) → clear error message, no crash
- [ ] Browse forward/back, both list modes (Settings ▸ Display ▸ List Mode)
- [ ] All sorts (date ↑↓, subject, size, priority) and all filters
      (sender/recipient/domain/subject/tag/evidence/attachment/type/pinned)
- [ ] Search: free text, Boolean, NEAR, `from:`/`has:attachment` operators,
      date range, regex; results past 2,000 keep paging
- [ ] Multi-select, Select All (symbolic), bulk tag/export/trash
- [ ] Pin/read/archive; Move to Trash → hidden from list, count and search;
      Restore → reappears searchable; Permanent Delete (explicit)
- [ ] Annotations, evidence tags, forensic badges; audit log export
- [ ] Clear & Start Fresh → archive empty; relaunch → NOTHING resurrects
- [ ] AI: general question (citations correct), thread question, insufficient-
      evidence abstention; Insights / Security brief / Digest
- [ ] Analytics, topics, predictive, duplicates, reports, exports (CSV/EML/
      PDF/Bates/Concordance); quit/reopen mid-use
- [ ] AI answer quality vs old build (bm25 retrieval — note any regression;
      retrieval limits are tunable)

## B. iPhone/iPad smoke

- [ ] Import, background/foreground during import, browse/search/detail,
      selection, filters, AI sheet, biometric lock, share/export,
      termination/resume, rotation/windowing

## C. Real public-v1 → v2 device migration

- [ ] Install current public v1, load a real archive + tags/review state
- [ ] Record count + a sample of message IDs/subjects
- [ ] Upgrade to the exact candidate; migration runs (JSON → SQLite direct,
      preserveAll, ID-coverage gate)
- [ ] Fresh reopen: verify count EXACT (duplicates preserved), sample content,
      sent/received, attachments metadata, tags, search
- [ ] Repeat with a mid-migration force-quit → relaunch → resume →
      exact identity, no duplicates, no loss
- [ ] Clear & Start Fresh after migration → relaunch → no resurrection

## D. App Store Connect / StoreKit

- [ ] Confirm actual product IDs, types, billing periods, prices, offers
      (do NOT trust old docs); tell the agent → it reconciles code/docs
- [ ] Free-tier limit value (`StoreManager.freeEmailLimit`) matches intent

## E. Screenshots / metadata

- [ ] Approve AppStoreMetadata.txt (claims were reconciled — S/MIME opaque-
      only, server-reported DKIM, AES-256 exports scope; keep it that way)
- [ ] Capture final screenshots (agent can stage exact states on request)

## F. Submission

- [ ] Archive + notarize/submit with your signing credentials
- [ ] Apple review feedback → hand to the agent for code/metadata fixes

## Defect loop

Device smoke finds a defect → agent fixes + adds regression coverage →
new candidate SHA → rerun only the affected manual items.
