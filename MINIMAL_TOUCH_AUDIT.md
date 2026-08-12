# mailin — Minimal‑Touch & Low‑Learning‑Curve Audit

Date: 2026‑08‑12. Grounded in current UX references (see Sources). Two audits:
**(A) Minimal touch** — fewest interactions to get a job done; **(B) Low
learning curve** — a first‑timer succeeds without training.

## Principles applied (from the references)
- **Hick's Law** — more choices = slower decisions. Minimize *decisions*, not
  just clicks. → Do **not** turn every tool into its own workflow; that adds
  choices. Keep a small set of guided recipes + one‑tap tools.
- **Fitts's Law** — big, close targets are faster; keep destructive actions
  away from primary ones. Touch targets ≥ 44×44 pt (Apple).
- **Progressive disclosure** — show the few important paths first; reveal the
  rest on demand.
- **Smart defaults** — pre‑pick the common choice so users proceed with no
  input. (Auto‑save, prefilled fields, remembered persona.)
- **Recognition over recall** (Nielsen #6) — surface options, histories, and
  saved state so users never have to remember across screens.
- **Flexibility for experts** (Nielsen #7) — keyboard/⌘K accelerate power users
  without complicating novices.

## A. Minimal‑touch findings → status
| # | Finding | Principle | Status |
|---|---|---|---|
| 1 | Saving a result required a click every time | Defaults / effort | **Fixed** — **Auto‑save my work** (Settings, default ON): tools record to Documents hands‑free after a short dwell; no Save click. |
| 2 | Guided jobs lead the hub ("Start a job" cards) | Progressive disclosure | Present — cards first, tool grid below. |
| 3 | Runs prefill from archive (case #, counts, dupes) | Smart defaults | Present — FieldDerivation. |
| 4 | Workflows auto‑advance to the next unlocked step | Effort | Present. |
| 5 | Command palette (⌘K) for direct navigation | Fitts / experts | Present. |
| 6 | Every tool one tap from the hub | Fitts | Present. |
| 7 | "Save Again / Generate Another" reuse the window | Effort | Present (report sheet). |

**Explicitly rejected (would *increase* touch):** wrapping each of the ~20
tools as its own multi‑step workflow. Per Hick's Law that multiplies choices
and steps. Instead, **auto‑save makes every tool a zero‑click recorded job** —
the intent (everything is a saved "job") with fewer, not more, interactions.

## B. Low‑learning‑curve findings → status
| # | Finding | Principle | Status |
|---|---|---|---|
| 1 | Persona hub scoped to that role's tools only | Hick / recognition | Present — strict per‑persona sections. |
| 2 | Each workflow shows a plain‑language purpose line | Recognition | Present. |
| 3 | "Suggested next" one‑tap hint | Recognition | Present (NextBestAction). |
| 4 | Documents tab shows recent numbers, searchable | Recognition (history) | Present. |
| 5 | Per‑feature `?` help + tooltips everywhere | Recognition | Present (HelpDot, tutorials). |
| 6 | Auto‑save status is visible ("Auto‑saved WF‑…") | Visibility of system status | **Added** with this change. |
| 7 | Glossary of legal/forensic terms | Recognition | Present. |

## Top recommendations still open (prioritized)
1. **First‑run 30‑second path**: on an empty archive, one primary CTA ("Import")
   and, right after import, auto‑select the persona's top workflow card. (Fitts
   + defaults.) — small.
2. **Consistent header pattern** across all tool windows (title · help · close
   in the same place) so recognition transfers between tools. — small sweep.
3. **Keyboard shortcuts** on the primary action of each tool window (⌘S save,
   ⌘R run) for experts. — small.
4. **"Recently used tools"** row on the hub (recognition of prior work). — small.

## What shipped in this pass
- **Auto‑save my work** toggle (Settings ▸ Documents & History, default **ON**).
- `SaveToDocumentsButton` now auto‑records hands‑free after a 1.5s dwell (a
  glance or mis‑tap posts nothing), showing "Auto‑saved WF‑…"; manual button
  mode when the setting is off.

## Sources
- [Laws of UX (Hick, Fitts, progressive disclosure) — uxness.in](https://www.uxness.in/2024/03/12-laws-of-ux-designing-with-principles.html)
- [Hick's Law — parallelhq.com](https://www.parallelhq.com/blog/what-hick-s-law)
- [Fitts' law UI best practices — LogRocket](https://blog.logrocket.com/ux-design/fitts-law-ui-examples-best-practices/)
- [Laws of UX — Nulab](https://nulab.com/learn/design-and-ux/laws-of-ux/)
- [Recognition vs Recall (Nielsen #6) — NN/g](https://www.nngroup.com/articles/recognition-and-recall/)
- [Recognition rather than Recall — The Decision Lab](https://thedecisionlab.com/reference-guide/design/recognition-rather-than-recall)
- [Nielsen's 10 Usability Heuristics — midrocket.com](https://midrocket.com/en/guides/nielsen-heuristics-usability/)
