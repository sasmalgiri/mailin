#!/usr/bin/env python3
"""Builds testOneNote.onepkg: a Microsoft cabinet (MS-CAB) holding two Apache Tika
OneNote sections in one MSZIP folder (several 32 KiB CFDATA blocks, so the DEFLATE
history must carry from block to block), one stored folder with a table-of-contents
stub, and one LZX folder (junk payload) that a reader must name and not open.

Run from this directory:  python3 make_onepkg.py
"""
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
TIKA = HERE.parent / "opensource" / "tika"
OUT = HERE / "testOneNote.onepkg"


def csum(data: bytes, seed: int = 0) -> int:
    s = seed
    whole = len(data) // 4 * 4
    for i in range(0, whole, 4):
        s ^= struct.unpack_from("<I", data, i)[0]
    rest = data[whole:]
    ul = 0
    if len(rest) == 3:
        ul |= rest[0] << 16
        ul |= rest[1] << 8
        ul |= rest[2]
    elif len(rest) == 2:
        ul |= rest[0] << 8
        ul |= rest[1]
    elif len(rest) == 1:
        ul |= rest[0]
    return (s ^ ul) & 0xFFFFFFFF


def mszip_blocks(payload: bytes) -> list[bytes]:
    blocks = []
    history = b""
    for i in range(0, len(payload), 32768):
        chunk = payload[i:i + 32768]
        if history:
            comp = zlib.compressobj(9, zlib.DEFLATED, -15, 9, 0, history)
        else:
            comp = zlib.compressobj(9, zlib.DEFLATED, -15)
        deflated = comp.compress(chunk) + comp.flush()
        blocks.append((b"CK" + deflated, len(chunk)))
        history = chunk[-32768:]
    return blocks


def cfdata(blocks) -> bytes:
    out = b""
    for compressed, uncompressed in blocks:
        header = struct.pack("<HH", len(compressed), uncompressed)
        out += struct.pack("<I", csum(header, csum(compressed))) + header + compressed
    return out


sections = [("Notebook/Section 1.one", (TIKA / "testOneNote2.one").read_bytes()),
            ("Notebook/Section 2.one", (TIKA / "testOneNote3.one").read_bytes())]
folder0_payload = b"".join(data for _, data in sections)
folder0_blocks = mszip_blocks(folder0_payload)

toc = bytes.fromhex("A12FFF43D9EF764C9EE210EA5722765F") + b"\0" * 48
folder1_blocks = [(toc, len(toc))]

lzx_junk = bytes(range(256)) * 4
folder2_blocks = [(lzx_junk, 4096)]

files = []
offset = 0
for name, data in sections:
    files.append((name, len(data), offset, 0))
    offset += len(data)
files.append(("Notebook/Open Notebook.onetoc2", len(toc), 0, 1))
files.append(("Notebook/Locked Section.one", 4096, 0, 2))

cffile = b""
for name, size, off, folder in files:
    cffile += struct.pack("<IIHHHH", size, off, folder, 0x5A21, 0x6000, 0x20) + name.encode("ascii") + b"\0"

folders = [(folder0_blocks, 1), (folder1_blocks, 0), (folder2_blocks, 3 | (15 << 8))]
header_size = 36
folder_table_size = 8 * len(folders)
coff_files = header_size + folder_table_size
data_start = coff_files + len(cffile)

cffolder = b""
datas = b""
for blocks, type_compress in folders:
    cffolder += struct.pack("<IHH", data_start + len(datas), len(blocks), type_compress)
    datas += cfdata(blocks)

total = data_start + len(datas)
cfheader = b"MSCF" + struct.pack("<IIIIIBBHHHHH", 0, total, 0, coff_files, 0, 3, 1, len(folders), len(files), 0, 0x1234, 0)
assert len(cfheader) == 36
OUT.write_bytes(cfheader + cffolder + cffile + datas)
print(f"wrote {OUT} ({total} bytes, {len(folder0_blocks)} MSZIP blocks)")
