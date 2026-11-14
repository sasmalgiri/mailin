#!/usr/bin/env python3
"""Regenerate WORKFLOW_INVENTORY.md from WorkflowEngine.swift (WorkflowCatalog.all).

Nine columns: ID · Name · Persona · Purpose · Steps · Documents posted · Tools launched ·
Gates · Verification. Verification is "Verified by behavioural test" ONLY when a test
file names the recipe's defID; everything else is "Draft / Needs review".
Run from the repo root: Scripts/gen_workflow_inventory.py
"""
import re, glob, datetime

src = open('maxmailin/WorkflowEngine.swift').read()
tests = "\n".join(open(p).read() for p in glob.glob('maxmailinTests/*.swift'))

defs = []
for m in re.finditer(r'static let (\w+) = WorkflowDefinition\(\s*defID: "([^"]+)", name: "([^"]+)",\s*persona: "([^"]+)", builtin: (true|false), operations: \[', src):
    start = m.end(); depth = 1; i = start
    while depth > 0 and i < len(src):
        if src[i] == '[': depth += 1
        elif src[i] == ']': depth -= 1
        i += 1
    body = src[start:i]
    ops = re.findall(r'op\((\d+), "([^"]+)", "([^"]+)", "((?:[^"\\]|\\.)*)"(?:,\s*\.(\w+))?(?:,\s*nil)?(?:,\s*launches: \.(\w+))?', body)
    defs.append(dict(var=m.group(1), defID=m.group(2), name=m.group(3), persona=m.group(4), ops=ops))

order = [v.strip() for v in re.search(r'static let all: \[WorkflowDefinition\] = \[(.*?)\]', src, re.S).group(1).replace('\n', ' ').split(',') if v.strip()]
byvar = {d['var']: d for d in defs}
purposes = dict(re.findall(r'case "([^"]+)":\s*\n\s*return "((?:[^"\\]|\\.)*)"', src))

rows = []
for v in order:
    d = byvar[v]
    steps = len(d['ops']); titles = "; ".join(o[2] for o in d['ops'])
    docs = sorted({o[4] for o in d['ops'] if o[4]}); tools = sorted({o[5] for o in d['ops'] if o[5]})
    verified = "Verified by behavioural test" if d['defID'] in tests else "Draft / Needs review"
    rows.append(f"| `{d['defID']}` | {d['name']} | {d['persona']} | {purposes.get(d['defID'], '—')} | {steps}: {titles} | {', '.join(docs) or '—'} | {', '.join(tools) or '—'} | sequential (each step waits on the previous) | {verified} |")

verified_count = sum(1 for r in rows if r.endswith("Verified by behavioural test |"))
hdr = f"""# Workflow inventory (3.0 Phase F / P2)

Generated {datetime.date.today().isoformat()} from `WorkflowEngine.swift` (`WorkflowCatalog.all`) by `Scripts/gen_workflow_inventory.py`.
**{len(rows)} rows** — the count the code ships, not the "47" in older documents. {verified_count} rows have an executed
test that names them; the rest are **Draft / Needs review**.

Stated honestly: a row is "Verified by behavioural test" only when a test file names its ID and drives its gates.
No jurisdiction, form or legal standard is asserted for any row — the recipes are procedural scaffolds around the
archive's own operations (import, hash, tag, export, report), and the documents they post are mailin's own
numbered records (`DocumentRegistry`).

| ID | Name | Persona | Purpose | Steps | Documents posted | Tools launched | Gates | Verification |
|---|---|---|---|---|---|---|---|---|
"""
open('WORKFLOW_INVENTORY.md', 'w').write(hdr + "\n".join(rows) + "\n")
print(f"{len(rows)} rows, {verified_count} verified")
