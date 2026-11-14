# RAR 7.0 test fixtures

Written 2026-11-09 on the development Mac with RARLAB's command-line **RAR 7.23 for macOS (arm64), trial
version** ("RAR 7.23 Copyright (c) 1993-2026 Alexander Roshal 27 Jun 2026"), downloaded from
https://www.rarlab.com/download.htm (`rarmacos-arm-723.tar.gz`, SHA-256
`68b393c000758d477fde43c955ff7542f12f76f3f5e87cdda923152fc791bd4d`). Owner decision 2026-11-09: the tool is
used only to make these test archives; it lives outside the repository (`~/mailin-rar-tool/`) and is
never shipped or committed. RAR 7.23 cannot write RAR 4.x / RAR 2.x archives.

The members are synthetic text written by this script (`gen.py`, Python 3), not mail:

```python
import random, sys, os
out = sys.argv[1] if len(sys.argv) > 1 else '.'
w = ['mail', 'archive', 'message', 'folder', 'attachment', 'duplicate', 'export', 'verify', 'search', 'alpha', 'beta', 'gamma']
for i in (1, 2, 3):
    random.seed(i)
    with open(os.path.join(out, f'member{i}.txt'), 'w') as f:
        f.write('\n'.join(' '.join(random.choice(w) for _ in range(12)) for _ in range(2000)) + '\n')
```

| member | bytes | SHA-256 |
|---|---|---|
| member1.txt | 173854 | 4735499765e8598998a2c88f69274f89617cd9a28decc49bcca0639175111f8b |
| member2.txt | 173925 | 2a5a5f9851f68d977c6350ff8b955db208cce83c9f5033bcc4660b25f743d10d |
| member3.txt | 174623 | 24bfcca2844807c8d49f7738f252fbb32495a86f7067df72ecf2543c3981867d |
| all.txt (`cat member1.txt member2.txt member3.txt`) | 522402 | e4e9a9f448ed21e40f1181612675518638984f2e1563f9cfbc7831aeec9bec7e |
| zz_padding.bin (`mkfile -n 4600m`, sparse zeros) | 4823449600 | — (not decoded by the tests) |

rar shrinks the dictionary it writes to what the input needs ("if the size of all source files is at
least twice less than the dictionary size"), so a RAR 7.0 (compression version 1) header needs either a
pipe (`-si`, size unknown when compression starts) or more than 4 GiB of input — hence the sparse
4.6 GB padding member, which compresses to ~190 KB. Every archive was checked with `rar t -mdx8g`
(rar refuses dictionaries over 4 GiB without `-mdx`): All OK.

| file | command (run in the folder holding the members) | what it is |
|---|---|---|
| rar7_v1_dict5g.rar | `rar a -md5g -simember1.txt rar7_v1_dict5g.rar < member1.txt` | version 1, dictionary 5 GiB (exponent 15 + 8/32), method 3 |
| rar5_v0_dict1g.rar | `rar a -md1g -simember1.txt rar5_v0_dict1g.rar < member1.txt` | version 0 (RAR 5.0 algorithm), dictionary 1 GiB — over libarchive's 64 MiB ceiling |
| rar7_v1_then_v0_solid.rar | `rar a -s -md5g -simember1.txt x.rar < member1.txt`, then `rar a -s -md5g x.rar member2.txt member3.txt` | solid: member1 version 1 (5 GiB), members 2–3 version 0 (1 MiB) continuing its stream |
| rar7_v1_solid_volumes.part00001…00003.rar | `rar a -s -ds -md5g -v100k solidvol.rar member1.txt member2.txt member3.txt zz_padding.bin` | solid, three volumes, every member version 1, dictionary 4.5 GiB (exponent 15 + 4/32); the padding member spans all three volumes |
| rar7_v1_pipe_volumes.part1…3.rar | `rar a -md5g -v24k -siall.txt v1vol.rar < all.txt` | version 1 over three volumes from a pipe: the first two volumes' headers record no unpacked size (flag 0x0008) |
| rar7_v1_encrypted.rar | `rar a -md5g -pmailin7 -simember2.txt v1enc.rar < member2.txt` | version 1, data encrypted (AES-256), password `mailin7` |
| rar7_v1_encrypted_headers.rar | `rar a -md5g -hpmailin7 -simember3.txt v1hp.rar < member3.txt` | version 1, headers and data encrypted, password `mailin7` |

| file | bytes | SHA-256 |
|---|---|---|
| rar5_v0_dict1g.rar | 20927 | ae0fefe277ca7c4d11a0fae9f02f70518ae57d066cbd0f47a6211131f73c38c9 |
| rar7_v1_dict5g.rar | 20930 | 3d94d76d84c429966df0001d4b853c038d2d2bc30d96cb1673b707b2e1d47f67 |
| rar7_v1_encrypted.rar | 21114 | 04f8c18b94e71d2c9779daca03404fb95201a0c8309018281291615b809399f5 |
| rar7_v1_encrypted_headers.rar | 21342 | ae4e4ee15dda83770476e5e37d97b89a85c617a78fb1af24f9778d53055b5d9f |
| rar7_v1_pipe_volumes.part1.rar | 24576 | b71d4dd30e97266e0645ff8f9d92a10db6895717f23095fce9357ad2dd90c11a |
| rar7_v1_pipe_volumes.part2.rar | 24576 | 716847816fa25bf9115e8fb46996fc19062cead8f979ea07942c49cd3d6de01a |
| rar7_v1_pipe_volumes.part3.rar | 10847 | abb87489d357c4dfb20ac811f191ee89fdc0551a7db0e29b6804fbe35a47facd |
| rar7_v1_solid_volumes.part00001.rar | 102400 | e3f328ac798a3e53e044d8f02c9c495b1f0ed0b7234aa1131ada49d27cfcf34e |
| rar7_v1_solid_volumes.part00002.rar | 102400 | a70d306b587a2b1e3a76a534f425336e87699d89c6e832a3558f2b03052c78d1 |
| rar7_v1_solid_volumes.part00003.rar | 49450 | b274300c25d18c187268ecd2fcacb8195926a8499bb244ca5a7018603ba11858 |
| rar7_v1_then_v0_solid.rar | 63318 | 5e3000ad9ffb0d23756dfdae99b9190a16632b3b90799ea53912c22fb3336009 |

Licence: the members are generated text made for these tests; the archives are mailin's (no third-party
content).
