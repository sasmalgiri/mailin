#!/usr/bin/env python3
"""Audit R6: two password-protected OpenDocument texts encrypted the way
LibreOffice 24.2+ writes them (package/source/zippackage/ZipPackage.cxx,
package/source/zipapi/ZipFile.cxx): start key SHA-256(password), Argon2id
key derivation (version 0x13, t=3, m=65536 KiB, p=4 — LibreOffice's fixed
values), AES-256-GCM (12-byte IV, cipher text followed by the 16-byte tag),
every encrypted stream raw-DEFLATEd before encryption.

  testODT_argon2id_gcm.odt            content.xml and styles.xml encrypted per entry
  testODT_argon2id_wholesome.odt      "wholesome" encryption: one encrypted stream
                                      `encrypted-package` holding the plain inner package

The crypto here is independent of mailin's Swift code: Argon2id from
argon2-cffi (the libargon2 reference implementation LibreOffice links) and
AES-GCM from `cryptography` (OpenSSL). Password: "mailin-argon2".

  python3 -m pip install --target /tmp/py argon2-cffi cryptography
  PYTHONPATH=/tmp/py python3 make_odf_argon2id.py
"""
import base64, hashlib, io, os, zipfile, zlib
from argon2.low_level import hash_secret_raw, Type
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PASSWORD = "mailin-argon2"
HERE = os.path.dirname(os.path.abspath(__file__))
MIME = "application/vnd.oasis.opendocument.text"
T, M, P = 3, 65536, 4

CONTENT = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
           'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.4">'
           '<office:body><office:text><text:h text:outline-level="1">Argon2id heading</text:h>'
           '<text:p>MAILIN-ARGON2ID-SENTENCE-20261109 sits inside the protected document.</text:p>'
           '</office:text></office:body></office:document-content>\n').encode()
STYLES = ('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
          'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
          'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.4">'
          '<office:master-styles><style:master-page style:name="Standard"><style:footer>'
          '<text:p>Argon2id footer</text:p></style:footer></style:master-page></office:master-styles>'
          '</office:document-styles>\n').encode()

START_KEY = hashlib.sha256(PASSWORD.encode()).digest()


def deflate(data):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def encrypt(plain):
    salt, iv = os.urandom(16), os.urandom(12)
    key = hash_secret_raw(START_KEY, salt, time_cost=T, memory_cost=M, parallelism=P, hash_len=32, type=Type.ID, version=19)
    return AESGCM(key).encrypt(iv, deflate(plain), None), salt, iv


def entry_xml(path, size, salt, iv, media="text/xml"):
    b = lambda x: base64.b64encode(x).decode()
    return (f' <manifest:file-entry manifest:full-path="{path}" manifest:media-type="{media}" manifest:size="{size}">\n'
            '  <manifest:encryption-data>\n'
            f'   <manifest:algorithm manifest:algorithm-name="http://www.w3.org/2009/xmlenc11#aes256-gcm" manifest:initialisation-vector="{b(iv)}"/>\n'
            '   <manifest:start-key-generation manifest:start-key-generation-name="http://www.w3.org/2000/09/xmldsig#sha256" manifest:key-size="32"/>\n'
            '   <manifest:key-derivation manifest:key-derivation-name="urn:org:documentfoundation:names:experimental:office:manifest:argon2id" '
            f'manifest:key-size="32" manifest:salt="{b(salt)}" loext:argon2-iterations="{T}" loext:argon2-memory="{M}" loext:argon2-lanes="{P}"/>\n'
            '  </manifest:encryption-data>\n'
            ' </manifest:file-entry>\n')


HEAD = ('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" '
        'xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0" manifest:version="1.4">\n')


def write(path, members):
    with zipfile.ZipFile(path, "w") as z:
        for name, data, method in members:
            z.writestr(zipfile.ZipInfo(name, (2026, 11, 9, 0, 0, 0)), data, compress_type=method)


def per_entry():
    manifest = HEAD + f' <manifest:file-entry manifest:full-path="/" manifest:version="1.4" manifest:media-type="{MIME}"/>\n'
    members = [("mimetype", MIME.encode(), zipfile.ZIP_STORED)]
    for name, plain in (("content.xml", CONTENT), ("styles.xml", STYLES)):
        cipher, salt, iv = encrypt(plain)
        members.append((name, cipher, zipfile.ZIP_STORED))
        manifest += entry_xml(name, len(plain), salt, iv)
    manifest += "</manifest:manifest>\n"
    members.append(("META-INF/manifest.xml", manifest.encode(), zipfile.ZIP_DEFLATED))
    write(os.path.join(HERE, "testODT_argon2id_gcm.odt"), members)


def wholesome():
    inner = io.BytesIO()
    inner_manifest = (HEAD + f' <manifest:file-entry manifest:full-path="/" manifest:version="1.4" manifest:media-type="{MIME}"/>\n'
                      ' <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\n'
                      ' <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>\n'
                      '</manifest:manifest>\n')
    with zipfile.ZipFile(inner, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype", (2026, 11, 9, 0, 0, 0)), MIME, compress_type=zipfile.ZIP_STORED)
        for name, data in (("content.xml", CONTENT), ("styles.xml", STYLES), ("META-INF/manifest.xml", inner_manifest.encode())):
            z.writestr(zipfile.ZipInfo(name, (2026, 11, 9, 0, 0, 0)), data, compress_type=zipfile.ZIP_DEFLATED)
    plain = inner.getvalue()
    cipher, salt, iv = encrypt(plain)
    manifest = (HEAD + f' <manifest:file-entry manifest:full-path="/" manifest:version="1.4" manifest:media-type="{MIME}"/>\n'
                + entry_xml("encrypted-package", len(plain), salt, iv, media=MIME) + "</manifest:manifest>\n")
    write(os.path.join(HERE, "testODT_argon2id_wholesome.odt"),
          [("mimetype", MIME.encode(), zipfile.ZIP_STORED), ("encrypted-package", cipher, zipfile.ZIP_STORED),
           ("META-INF/manifest.xml", manifest.encode(), zipfile.ZIP_DEFLATED)])


if __name__ == "__main__":
    per_entry()
    wholesome()
    for name in ("testODT_argon2id_gcm.odt", "testODT_argon2id_wholesome.odt"):
        print(name, os.path.getsize(os.path.join(HERE, name)), "bytes")
