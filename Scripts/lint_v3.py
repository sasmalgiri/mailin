#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
3.0 audit-lesson lints (SCALE_TODO_3_0.md §F9 / R2).

The rules here MUST match `maxmailinTests/V3LintTests.swift` (the test is
what fails the suite; this script reports and writes the old-file baseline).

  python3 Scripts/lint_v3.py            report violations (exit 1 if any new)
  python3 Scripts/lint_v3.py --baseline rewrite Scripts/lint_v3_baseline.json

Files that existed before the 3.0 engines pass (commit 21679da) are "old":
their per-rule counts are a ceiling that may only go down (allow-listed until
R1). Every other file is "new" and must have zero violations. A line holding
`lint:allow` is skipped (state the reason on the line).
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = ["maxmailin", "Packages/ArchiveCore/Sources/ArchiveCore"]
BASELINE = os.path.join(ROOT, "Scripts", "lint_v3_baseline.json")
OLD_COMMIT = "21679da"

LINE_RULES = {
    "discardedSaveOutcome": r"_\s*=\s*(?:await\s+)?(?:PlatformFileSaver|PlatformExport)\.",
    "workingSetCap":        r"workingSet\(query:[^)]*cap:",
    "countBreakCap":        r"count\s*>=?\s*[0-9][0-9_]*\s*\{\s*break",
    "forceCast":            r"\bas!\s",
    "forceTry":             r"\btry!\s",
    "silentUserWrite":      r"try\?\s+[^\n]*\.write\(to:\s*url\b",
    "unmanagedSavePanel":   r"\bNSSavePanel\(\)",
}
# Pair rules: a line matching `first` with a line matching `second` within N lines after it.
PAIR_RULES = {
    "documentBeforeSave": (r"DocumentRegistry\.(?:capture|post)", r"PlatformExport\.save|PlatformFileSaver\.", 30),
}
# Near rules: a line matching `a` within N lines (either side) of a line matching `b`.
NEAR_RULES = {
    "allNextToCap": (r"(?:Text\(|String\(localized:\s*)\"All\b", r"\.prefix\(\s*[0-9]{2,}", 15),
}


def code_lines(text):
    out = []
    for line in text.split("\n"):
        t = line.strip()
        if t.startswith("//") or t.startswith("*") or t.startswith("/*") or "lint:allow" in line:
            out.append("")
        else:
            out.append(line)
    return out


def lint_file(path):
    lines = code_lines(open(path, encoding="utf-8").read())
    counts = {}
    for rule, pat in LINE_RULES.items():
        rx = re.compile(pat)
        n = sum(1 for l in lines if rx.search(l))
        if n: counts[rule] = n
    for rule, (a, b, span) in PAIR_RULES.items():
        ra, rb = re.compile(a), re.compile(b)
        n = 0
        for i, l in enumerate(lines):
            if ra.search(l) and any(rb.search(x) for x in lines[i + 1:i + 1 + span]):
                n += 1
        if n: counts[rule] = n
    for rule, (a, b, span) in NEAR_RULES.items():
        ra, rb = re.compile(a), re.compile(b)
        n = 0
        for i, l in enumerate(lines):
            if ra.search(l) and any(rb.search(x) for x in lines[max(0, i - span):i + span + 1]):
                n += 1
        if n: counts[rule] = n
    return counts


def swift_files():
    for d in DIRS:
        base = os.path.join(ROOT, d)
        for name in sorted(os.listdir(base)):
            if name.endswith(".swift"):
                yield f"{d}/{name}"


def old_files():
    out = subprocess.check_output(["git", "-C", ROOT, "ls-tree", "-r", "--name-only", OLD_COMMIT, "--"] + DIRS, text=True)
    return {p for p in out.split("\n") if p.endswith(".swift")}


def main():
    old = old_files()
    current = {rel: lint_file(os.path.join(ROOT, rel)) for rel in swift_files()}
    if "--baseline" in sys.argv:
        baseline = {rel: c for rel, c in current.items() if rel in old and c}
        with open(BASELINE, "w", encoding="utf-8") as f:
            json.dump({"oldCommit": OLD_COMMIT, "oldFiles": sorted(old), "ceilings": baseline}, f, indent=1, sort_keys=True)
            f.write("\n")
        print(f"baseline: {sum(sum(c.values()) for c in baseline.values())} old-file sites in {len(baseline)} files")
        return 0
    data = json.load(open(BASELINE, encoding="utf-8"))
    ceilings = data["ceilings"]
    bad = []
    for rel, c in current.items():
        for rule, n in c.items():
            allowed = ceilings.get(rel, {}).get(rule, 0) if rel in old else 0
            if n > allowed:
                bad.append(f"{rel}: {rule} {n} (allowed {allowed})")
    print("\n".join(bad) if bad else "clean")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
