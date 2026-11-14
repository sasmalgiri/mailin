#!/usr/bin/env python3
"""V4-01 / V4-14: add the `Release-Connected` build configuration to maxmailin.xcodeproj.

Duplicates every `Release` XCBuildConfiguration (project + every target) as
`Release-Connected`, then, for target `maxmailin` only, sets:
  SWIFT_ACTIVE_COMPILATION_CONDITIONS = "MAILIN_CONNECTED_MAIL $(inherited)"   (no NO_NETWORK_BUILD)
  CODE_SIGN_ENTITLEMENTS             = mailin/mailin-connected.entitlements   (iphoneos line unchanged)
  INFOPLIST_FILE                     = Info-Connected.plist
  MAILIN_GMAIL_CLIENT_ID / MAILIN_GRAPH_CLIENT_ID = "" (owner fills them, step 4)
`Release` itself is not touched. Also writes the shared scheme "maxmailin Connected"
(Archive uses Release-Connected).

Rule 12: run only while Xcode is NOT running. Usage:
  Scripts/add-connected-config.py [path/to/maxmailin.xcodeproj]
Idempotent: refuses if Release-Connected already exists.
"""
import os
import re
import secrets
import subprocess
import sys

NEW = "Release-Connected"


def main():
    proj = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "maxmailin.xcodeproj")
    proj = os.path.abspath(proj)
    if os.environ.get("MAILIN_ALLOW_XCODE_OPEN") != "1" and \
            subprocess.run(["pgrep", "-x", "Xcode"], capture_output=True).returncode == 0:
        sys.exit("Xcode is running: quit it first (rule 12).")
    path = os.path.join(proj, "project.pbxproj")
    text = open(path, encoding="utf-8").read()
    if f"/* {NEW} */" in text:
        sys.exit(f"{NEW} already exists; nothing changed.")
    used = set(re.findall(r"\b[0-9A-F]{24}\b", text))

    def new_id():
        while True:
            i = secrets.token_hex(12).upper()
            if i not in used:
                used.add(i)
                return i

    # Configuration lists: which list owns which Release configuration.
    lists = re.finditer(r"\t\t[0-9A-F]{24} /\* Build configuration list for (\w+) \"([^\"]+)\" \*/ = \{\n"
                        r"\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = \(\n(.*?)\t\t\t\);", text, re.S)
    owner = {}
    for m in lists:
        for cid in re.findall(r"([0-9A-F]{24}) /\* Release \*/", m.group(3)):
            owner[cid] = (m.group(1), m.group(2))
    if not owner:
        sys.exit("no Release configurations found; project layout not recognised.")
    if ("PBXNativeTarget", "maxmailin") not in owner.values():
        sys.exit("target maxmailin has no Release configuration; nothing changed.")

    for cid, (kind, name) in owner.items():
        block_re = re.compile(r"(\t\t" + cid + r" /\* Release \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n.*?\n\t\t\};\n)", re.S)
        block = block_re.search(text)
        if not block:
            sys.exit(f"Release block {cid} not found.")
        nid = new_id()
        copy = block.group(1).replace(f"{cid} /* Release */", f"{nid} /* {NEW} */", 1)
        copy = copy.replace("\t\t\tname = Release;\n", f"\t\t\tname = \"{NEW}\";\n", 1)
        if kind == "PBXNativeTarget" and name == "maxmailin":
            copy = connected_settings(copy)
        text = text[:block.end()] + copy + text[block.end():]
        # Register it in its list, right after Release.
        text = re.sub(r"(\t\t\t\t" + cid + r" /\* Release \*/,\n)", r"\1" + f"\t\t\t\t{nid} /* {NEW} */,\n", text, count=1)

    open(path, "w", encoding="utf-8").write(text)
    write_scheme(proj)
    print(f"{NEW} added to {len(owner)} configuration lists; scheme 'maxmailin Connected' written.")


def set_setting(block, key, value):
    line_re = re.compile(r"\t\t\t\t" + re.escape(key) + r" = .*?;\n")
    line = f"\t\t\t\t{key} = {value};\n"
    if line_re.search(block):
        return line_re.sub(lambda _: line, block, count=1)
    return block.replace("\t\t\tbuildSettings = {\n", "\t\t\tbuildSettings = {\n" + line, 1)


def connected_settings(block):
    block = set_setting(block, "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "\"MAILIN_CONNECTED_MAIL $(inherited)\"")
    block = set_setting(block, "CODE_SIGN_ENTITLEMENTS", "\"mailin/mailin-connected.entitlements\"")
    block = set_setting(block, "INFOPLIST_FILE", "\"Info-Connected.plist\"")
    block = set_setting(block, "MAILIN_GMAIL_CLIENT_ID", "\"\"")
    block = set_setting(block, "MAILIN_GRAPH_CLIENT_ID", "\"\"")
    if "NO_NETWORK_BUILD" in block or "MAILIN_CLOUD_AI" in block:
        sys.exit("connected configuration still names NO_NETWORK_BUILD or MAILIN_CLOUD_AI; nothing written.")
    return block


def write_scheme(proj):
    schemes = os.path.join(proj, "xcshareddata", "xcschemes")
    src = open(os.path.join(schemes, "maxmailin.xcscheme"), encoding="utf-8").read()
    archive = re.compile(r"(<ArchiveAction\s+buildConfiguration = \")Release(\")")
    if not archive.search(src):
        sys.exit("maxmailin.xcscheme has no Release ArchiveAction.")
    open(os.path.join(schemes, "maxmailin Connected.xcscheme"), "w", encoding="utf-8").write(archive.sub(r"\1" + NEW + r"\2", src, count=1))


if __name__ == "__main__":
    main()
