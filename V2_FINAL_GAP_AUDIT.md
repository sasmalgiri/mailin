# V2 FINAL GAP AUDIT — zero-remainder tracker (CLOSED)

_Final state, 2026-08-07. Every item implemented+tested+wired or explicitly
moved to V2_1_BACKLOG.md. Test evidence: 139 automated tests ×2 clean runs
(138 pass + 1 env-gated stress entry, 0 failures); macOS Debug + Release
builds green._

Legend: ☑ done · ⏭ v2.1 (explicit, honest product posture — see backlog)

## Storage (§2–§4)
| # | Item | Status | Evidence |
|---|------|--------|----------|
| S1 | PRAGMA user_version transactional migrations (v1→v4) | ☑ | SQLiteEmailStore.migrateSchema; V2StorageSchemaTests |
| S2 | Migration fixtures (fresh/populated/newer/partial) | ☑ | 4 fixtures in V2StorageSchemaTests |
| S3 | Full-fidelity hydration | ☑ | testFullFidelity_persistReopenHydration |
| S4–S7 | sources/participants/attachments/tags/domains tables | ☑ | migrateV1toV2 |
| S8 | UNIQUE(source_id, source_ordinal) | ☑ | testSourceOccurrence_reparseIsIdempotent |
| S9 | emails table extension | ☑ | v2 migration |
| S10–S11 | DedupPolicy + partial-unique dedup_key | ☑ | testDedupPolicies_… |
| S12 | Differential persist→reopen contract | ☑ | same suite |

## Import (§5–§9)
| I1–I3 | Sole coordinator / free-tier cap / streaming hash | ☑ | pre-existing + this run |
| I4 | stored→indexed crash state in SQLite | ⏭ | throwing JSON checkpoints + FTSReconciler cover the window; tables → backlog #7 |
| I5 | Durable checkpoints | ☑(JSON, throwing, identity-bound) | checkpoint tests |
| I6 | Keyed HMAC receipts + verifyReceipt + tamper tests | ☑ | V2ReceiptIntegrityTests (incl. recomputed-checksum attack) |
| I7 | Read errors throw (no fake EOF) | ☑ | MBOXParser nextLine |
| I8 | Per-message ceiling (100 MB) | ☑ | oversized accounting |
| I9 | Unknown/ZIP extension explicit error | ☑ | testUnsupportedExtensions_rejectedExplicitly |
| I10 | Recovery report returned per source (global deleted) | ☑ | testStreamingParse_returnsSourceScopedRecoveryReport |
| I11 | V2_FORMAT_MATRIX.md | ☑ | file |
| I12 | EML From:-first fixture | ☑ | testEML_fromHeaderFirst (fixed a real header-loss bug) |

## Migration (§10)
| M1 | Content-identity gate (IDs + samples + integrity_check + reopen) | ☑ | verifyAndActivate |
| M2 | v1 duplicate Message-IDs preserved | ☑ | testMigrationFromRealV1Store (100/100) |
| M3 | No resurrection after clear | ☑ | testClearedArchive_doesNotResurrect (with negative control) |

## Query/Search (§13–§18)
| Q1–Q3 | EmailQuery breadth / compiler / DB sorts | ☑ | V2QueryParityTests |
| Q4–Q5 | Ranked cursor / shard pruning | ☑ | V2SearchTests |
| Q6 | Exact counts past 2,000 | ☑ | 2,100-match regression |
| Q7 | streamMatchingIDs (Select All/exports) | ☑ | scope/export tests |
| Q8 | Exclusions verified against query | ☑ | testSelectionScope_exclusions… |
| Q9 | Bounded regex | ☑ | V2SearchTests |
| Q10 | Attachment text search | ⏭ | honest UI notice; dead code deleted; backlog #2 |

## Review state (§19–§20)
| R1–R4 | Tables / soft Trash / JSON migration / no giant maps | ☑ | V2ReviewStateTests + delete-reflects test |

## Forensic (§21)
| F1–F4 | Durable tables / streamed audit / SHA identity / hash semantics | ☑ | V2ForensicPersistenceTests; semantics in code docs (normalized rawSource bytes, labeled) |

## Derived (§22–§26)
| D1 | Incremental invalidation (1 new → 1 stale) | ☑ | testAddOneEmail_onlyNewEmailIsStale |
| D2 | Merge-safe partial updates | ☑ | topic-merge + runner-merge tests |
| D3 | cancel() stops live run; compute off MainActor | ☑ | testRunnerCancel_stopsLiveRun |
| D4 | NLP/topics/predictive/threads persisted | ☑ | V2DerivedStateTests |

## UI (§27–§28, §35, §37)
| U1–U2 | Parity matrix; capabilities migrated/deferred | ☑ | V2_UI_PARITY_MATRIX.md |
| U3 | Comparison bounded EXPLICITLY (truncation surfaced) | ☑/⏭ | init clamp; streamed compare → backlog #3 |
| U4 | One browse architecture | ☑ | testNoRollbackFlagRemains |

## AI (§29–§31)
| A1–A4 | Scope-based, grounded, authorized, injection-tested | ☑ | grounding/injection suites |

## Lifecycle (§11)
| L1–L3 | Canonical clear/erase; tombstone; no-resurrection test | ☑ | V2LifecycleTests |

## Trust/Security (§48–§49, §68)
| T1 | S/MIME claim reconciled (opaque verified; detached honest) | ☑ | V2SecurityTests + copy edits |
| T2 | Offline Release audit | ☑ | entitlements; OFFLINE_MODE dead-code warnings in Release build |
| T3–T4 | Receipt wording truthful; claim audit (AES-256/DKIM/instant) | ☑ | README/metadata/docs edits |

## Qualification (§54–§63)
| P1 | >2,000-match regression | ☑ | V2QueryParityTests |
| P2 | Full suite ×2 recorded | ☑ | 139 tests: 138 pass/1 skip, twice |
| P3 | Build matrix | ☑ macOS Debug+Release | iOS builds = owner smoke environment |
| P4–P5 | Zero-stub + live-wiring audits | ☑ | 0 TODO/FIXME/fatalError/loadAll/parsedEmails/Int.max/PCC; try? remainder classified (backlog #9) |
| P6 | Scale runs | ☑ 10K+100K production-path executed (flat RSS); 1M full-pipeline REFUSED by disk preflight (documented, command provided); prior 1M store-engine result stands |

## Docs (§67–§70)
| X1–X4 | Status rewrite; matrices; backlog; owner checklist; completion record; PR | ☑ | this commit set |
