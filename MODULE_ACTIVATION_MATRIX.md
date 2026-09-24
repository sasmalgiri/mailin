# Module and capability activation matrix

Two levels of switch:

- **Page** (`AppModule`) — Archive, AI Insights, Professional Workflows, Live
  Mail. Archive is mandatory; the other three are off on a fresh install.
- **Capability** (`Capability`) — an individual engine, job or surface inside a
  page. Each has its own switch.

`ModuleRegistry.isOn(_:)` requires **both**, plus every declared dependency.
The page check comes first and is not overridable, so a stored "on" flag can
never resurrect a disabled page's work — that is what keeps the
page-independence rules (`V3_0_PLAN.md` §3.3 R1–R6) true regardless of what
the capability table says.

Written 2026-09-24. **The resting-cost numbers below are measured; the
per-capability numbers are not — see §4.**

---

## 1. Design rules

| Rule | Why | Enforced by |
|---|---|---|
| A capability cannot run while its page is off | A stale flag must not defeat page independence | `ModuleRegistry.block` checks the page first |
| Off means dormant, never destructive | Switching a feature off must not cost the user work | `Capability.whenOff`, asserted by `testEveryCapabilityExplainsWhatSurvivesBeingSwitchedOff` |
| New and unproven defaults to OFF | Installing an update must not change how an archive behaves | `Capability.maturity` → `defaultsOn`, asserted by `testMaturityAndDefaultAgree` |
| Dependencies are declared, not implied | A dimmed row must name the reason | `Capability.requires`, surfaced as `CapabilityBlock.dependencyOff` |
| An absent stored key means "default", not "off" | A capability added later must not arrive disabled | `ModuleState.isCapabilitySet` |

---

## 2. Page matrix

| Page | Default | Owns capabilities | Switching off keeps |
|---|---|---|---|
| Archive | **always on** | 7 | — (cannot be switched off) |
| AI Insights | off | 9 | Saved summaries, digests, reports; tags |
| Professional Workflows | off | 11 | Cases, custodians, holds, documents, audit chain |
| Live Mail | off | 0 | Nothing to keep — no account can be added in this build |

Live Mail deliberately owns no capability switches: every one of its features
is `.notInThisBuild`, and offering switches that cannot work would be a lie in
the UI. Asserted by `testEveryCapabilityHasAnOwnerAndLiveMailOwnsNone`.

---

## 3. Capability matrix

### Archive (Page 1)

| Capability | Maturity | Default | What it changes | Off means |
|---|---|---|---|---|
| `blobTier` | Preview | **off** | Raw MIME over 8 MB stored beside the database instead of in the row | Existing external bodies still read; new messages over 8 MB fail to import |
| `offsetParser` | **Experimental** | **off** | Boundary scan + header-only parse; removes the 100 MB single-message ceiling | Streaming parser as before; a message over 100 MB is reported damaged and skipped |
| `locatorReads` | **Experimental** | **off** | Attachments and exports read from byte ranges in the source | Re-parse of the stored raw MIME, as before |
| `externalStorage` | Preview | **off** | Archive can live on a chosen local volume | The archive stays where it is; only the chooser is hidden |
| `guidedImport` | Preview | **off** | Pre-import sheet: format, cost, caveats, engine | Import starts on selection, as 2.x; preflight and receipt still run |
| `importQueue` | Preview | **off** | Session list of pending / running / finished imports | Progress in the toolbar only; receipts still written |
| `searchCoverageBadge` | Stable | on | Note under search results when messages are only partly indexed | Note hidden; coverage still recorded per message |

Dependencies: `locatorReads` → `offsetParser` → `blobTier`;
`importQueue` → `guidedImport`.

### AI Insights (Page 2)

`aiAssistant`, `aiDigest`, `anomalyDetection`, `smartAutoTagger`,
`topicClusters`, `threadSummarizer`, `smartAlerts`, `keywordMonitor`,
`predictiveCoding` — all Stable, all on by default **once the page is on**.

Switching all of them off also stops the background analysis pass from being
scheduled at launch: there would be nothing for it to produce.

### Professional Workflows (Page 3)

`custodianPanel`, `reviewBatches`, `auditTrail`, `eDiscovery`,
`batesNumbering`, `redaction`, `gdprReport`, `chainOfCustody`,
`investigationReport`, `reportBuilder`, `reasoningStudios` — all Stable, all on
by default once the page is on.

`auditTrail` / `chainOfCustody` off means **no new entries are appended**; the
existing chain is kept intact and stays verifiable. No legal hold is ever
lifted by switching anything off.

---

## 4. Measurements

Executed 2026-09-24 by `maxmailinTests/ActivationMeasurementTests.swift`.

**Method, because it decides what the numbers are worth.** `phys_footprint` is
process-wide and was measured earlier in this project to vary ±15% across
identical runs — four memory hypotheses were falsified that way during P3. So
per-page cost is reported as **counts**, which are exact and attributable, and
the engine claim is reported as a **delta between two engines over the same
file in the same process**, where the engine is the only variable.

### Resting cost — Page 1 only

| Measure | Result |
|---|---|
| Enabled pages | `archive` |
| Live feature hosts | **0** |
| Running jobs | **0** |
| `isArchiveOnlyClean` | **true** |
| Process footprint | 193 MiB (test host; context, not attribution) |
| Network sockets (Release) | **0** |

### Per-page activation cost

| Page enabled | Hosts built | Jobs started | Capabilities running |
|---|---|---|---|
| `aiInsights` | **0** | **0** | 9 of 9 |
| `professional` | **0** | **0** | 11 of 11 |
| `liveMail` | **0** | **0** | 0 of 0 |

The zeros are the point: **enabling a page constructs nothing and starts
nothing.** The host is built on first *use* via `host(for:)`, so a page the
user switches on but never opens costs the same as one that is off. Enabling
one page leaves every other page's capabilities off — asserted, not assumed.

### Capability defaults, as shipped

27 capabilities · 20 default-on · **7 default-off** · running on a fresh
install: **1** (`searchCoverageBadge`, the only stable Archive capability).
Every unproven engine is off and every running capability on a fresh install
is Archive-owned and Stable — both asserted.

### S4 — the claim the offset parser rests on

**An earlier version of this section published "3.0 MiB peak, ~24× less than
the streaming parser". That number was an artifact and is withdrawn.** It came
from sampling `phys_footprint` inside `onBatch`, which fires once per message,
so on a three-message fixture it looked three times and never during the
climb. Per-window sampling gives a different and much less flattering picture.

Measured per window (`testMeasure_peakIsIndependentOfMessageSize`):

| Fixture | File size | Peak footprint delta |
|---|---|---|
| 2 messages × 24 MiB | 48 MiB | **46.1 MiB** |
| 48 messages × 1 MiB | 48 MiB | **47.9 MiB** |
| 8 messages × 24 MiB | 192 MiB | **109.4 MiB** |

What this does and does not support:

- **Supported: peak is independent of MESSAGE size.** 2 × 24 MiB and
  48 × 1 MiB cost the same. That is the property that makes a single huge
  message importable at all, and it is what the streaming parser lacks — its
  unit of work is the message as a `String`, which is why it needed a 100 MB
  ceiling.
- **NOT supported: a fixed window + headers ceiling.** Peak grows with FILE
  size, sub-linearly (~100% of a 48 MiB file, ~57% of a 192 MiB one). The
  likely mechanism is the unified buffer cache, which `phys_footprint` charges
  to the process; those pages are evictable under memory pressure, but Jetsam
  counts them, so on iOS this matters and should not be described as free.

Between batches — the question "what is the engine holding while it hands me
work" — the per-message figure is ~3 MiB, and that is still true. It is simply
not the peak.

**Process baseline dominates every absolute figure, and this defeated three
attempted conclusions.** The same fixture measured 46 MiB in one process,
0.0 MiB inside the test suite, and ~30 MiB in a third — because
`phys_footprint` includes whatever the process had already allocated. A
`F_NOCACHE` experiment appeared to give a 10× improvement and turned out to be
nothing but this effect (29.3 vs 29.5 MiB once measured one configuration per
process; see `SIZE_LIMITS_DESIGN.md` §S4).

Treat the absolute numbers above as one machine's readings under one set of
conditions, not as a specification. This is also why per-page and
per-capability cost is reported as **counts** elsewhere in this document:
counts are exact, footprint deltas are not.

The message-size independence holds in both contexts (46.1 vs 47.9 cold;
0.0 vs 2.3 warm), which is why that is the claim being made and the absolute
ceiling is not.

### S4 — throughput

2,000 ordinary messages (630 KB), same file, same process:

| Engine | Rate |
|---|---|
| Streaming parser | **4,261 msg/s** (1.3 MiB/s) |
| Offset engine | **3,660 msg/s** (1.1 MiB/s) |

The offset engine is ~14% slower on small messages, which is the seek-per-
message cost of reading each range back for full parsing. That is the expected
trade and it is the right one: the cost is paid on the common case to make the
impossible case possible. Not asserted in the test — a single timing run on a
shared machine is not a benchmark — only printed.

Outcome difference for a 110 MiB message:

| Engine | Result |
|---|---|
| Streaming parser | imported **0**, damaged 1 (`oversized_message`) |
| Offset engine | imported **1**, damaged 0 |

That is the whole reason S4 exists: the message is currently **lost**.

### S4 — the caveat measurement found

Peak tracks the longest **line**, not the message, because the scanner
accumulates bytes until it finds a newline:

| 12 MiB body | Peak delta |
|---|---|
| 76-column lines (normal mail, base64 wrap) | **0.0 MiB** |
| One unbroken 12 MiB line | **16.5 MiB** |

So "no message size limit" is precise only for line-structured mail — which
is what mail is: RFC 5322 recommends 78 columns and base64 wraps at 76. An
unwrapped body is **bounded** by `maxLineBytes` (16 MiB), not unbounded, and
that bound is why a pathological file cannot exhaust memory.

This was found by a fixture bug: the first version of the measurement wrote
each body as one line and showed the offset engine holding 18.9 MiB, which
looked like the claim failing. It was the fixture being unrealistic AND a real
property worth stating, so it is now measured deliberately
(`testMeasure_peakTracksLongestLineNotMessage`) rather than discovered by
accident.

### Measurement environment — a caveat on this run

The machine these numbers come from was at **95% disk** (10 GiB free of
228 GiB, of which ~10 GB is Xcode DerivedData). Two tests that write
~190 MB through SQLite began failing with `disk I/O error` partway through
the session — first `testProductionPathImport_realMBOXFixture_measured`,
then `testArchive_exportsMBOXThatReparses`, both of which had passed earlier
in the same session on the same code.

A failure that **moves between runs** and whose error is `disk I/O error` is
resource exhaustion, not a logic defect. It is recorded here rather than
dismissed, because it also means the memory figures above were taken on a
machine under storage pressure, and should be re-taken on a machine with
headroom before they are quoted anywhere external.

The measurement tests now clean up their own fixtures (they write up to
110 MiB each), which was a real contribution to the pressure.

### Still not measured

- Import **throughput** (messages/second) offset versus streaming. The memory
  question was the one the design rested on; speed is a separate claim and
  nothing in the docs asserts it yet.
- Footprint on a real multi-gigabyte archive, as opposed to synthetic
  fixtures. The 526 MiB / 20-shard idle figure in `RELEASE_READINESS.md` is
  from a Release app run and is not reproduced here.

---

## 5. How a user reaches it

Settings ▸ Modules shows the four page cards, then a **Features** section with
a per-page "Features…" button and a "Show the full matrix…" button, both
opening `CapabilityMatrixView`.

Each row shows: whether it is running now; if not, why not (page off, switched
off, or which dependency is off); its maturity; and — when off — what happens
to work already done. A row whose switch is on but which is not running is
never silently inert.
