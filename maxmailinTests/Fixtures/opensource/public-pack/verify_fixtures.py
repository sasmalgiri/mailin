#!/usr/bin/env python3
"""Verify delivered fixture identities and structural expectations; not a mailin test."""
from pathlib import Path
import hashlib
import json
import zipfile
import xml.etree.ElementTree as ET
from email import policy
from email.parser import BytesParser

ROOT = Path(__file__).resolve().parent
W = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def main():
    count = 0
    for line in (ROOT / 'SHA256SUMS').read_text().splitlines():
        wanted, name = line.split('  ', 1)
        actual = digest((ROOT / name).read_bytes())
        if actual != wanted:
            raise ValueError('Hash mismatch: ' + name)
        count += 1
    expected = json.loads((ROOT / 'expected_results.json').read_text())
    for entry in expected['word']:
        with zipfile.ZipFile(ROOT / entry['path']) as z:
            if z.testzip() is not None:
                raise ValueError('Invalid ZIP CRC: ' + entry['path'])
            doc = ET.fromstring(z.read('word/document.xml'))
            actual = []
            for kind in ['ins', 'del', 'moveFrom', 'moveTo']:
                for node in doc.iter(W + kind):
                    actual.append({'kind': kind, 'text': ''.join(node.itertext()),
                                   'id': node.get(W + 'id'), 'author': node.get(W + 'author'),
                                   'date': node.get(W + 'date')})
            if actual != entry['revisions']:
                raise ValueError('Revision mismatch: ' + entry['path'])
    for entry in expected['eml_wrappers']:
        message = BytesParser(policy=policy.default).parsebytes((ROOT / entry['path']).read_bytes())
        parts = list(message.iter_attachments())
        if len(parts) != 1 or digest(parts[0].get_payload(decode=True)) != entry['attachment_sha256']:
            raise ValueError('Wrapped attachment mismatch: ' + entry['path'])
    oft = (ROOT / expected['outlook']['path']).read_bytes()
    if oft[:8] != bytes.fromhex('d0cf11e0a1b11ae1'):
        raise ValueError('OFT is not a compound file')
    print(f'PASS: {count} file hashes, 4 DOCX revision structures, 7 unchanged wrapped attachments, OFT signature.')
    print('Archive password/extraction evidence is in expected_results.json. Run mailin acceptance tests separately.')

if __name__ == '__main__':
    main()
