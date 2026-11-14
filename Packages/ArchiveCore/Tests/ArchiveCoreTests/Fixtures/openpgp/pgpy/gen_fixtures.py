# Fixture generator for mailin's OpenPGP verification tests (GAP-PGP, 2026-11-07).
# Independent writer: PGPy 0.6.0 (pure-Python OpenPGP) on pyca/cryptography 50.0.2.
# Only PUBLIC keys and signed data are written; the secret keys live in memory only.
import os, sys, hashlib, warnings
from datetime import datetime, timedelta, timezone
warnings.simplefilter("ignore")
import pgpy
from pgpy.constants import PubKeyAlgorithm, KeyFlags, HashAlgorithm, EllipticCurveOID, CompressionAlgorithm, RevocationReason

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def w(name, data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)

MEMO = b"Quarterly board memo\nThe numbers are final.\nSigned off by finance.\n"
w("memo.txt", MEMO)

def newkey(alg, param, name, email, hash_, created=None, expiry=None):
    k = pgpy.PGPKey.new(alg, param, created=created)
    uid = pgpy.PGPUID.new(name, email=email)
    prefs = dict(usage={KeyFlags.Sign, KeyFlags.Certify}, hashes=[hash_], primary=True)
    if created: prefs["created"] = created
    if expiry: prefs["key_expiration"] = expiry
    k.add_uid(uid, **prefs)
    return k

keys = {
    "rsa3072":   (newkey(PubKeyAlgorithm.RSAEncryptOrSign, 3072, "Rhea RSA", "rhea@example.org", HashAlgorithm.SHA256), HashAlgorithm.SHA256),
    "ed25519":   (newkey(PubKeyAlgorithm.EdDSA, EllipticCurveOID.Ed25519, "Ed Legacy", "ed@example.org", HashAlgorithm.SHA256), HashAlgorithm.SHA256),
    "nistp256":  (newkey(PubKeyAlgorithm.ECDSA, EllipticCurveOID.NIST_P256, "Pat P256", "p256@example.org", HashAlgorithm.SHA256), HashAlgorithm.SHA256),
    "nistp384":  (newkey(PubKeyAlgorithm.ECDSA, EllipticCurveOID.NIST_P384, "Pia P384", "p384@example.org", HashAlgorithm.SHA384), HashAlgorithm.SHA384),
    "nistp521":  (newkey(PubKeyAlgorithm.ECDSA, EllipticCurveOID.NIST_P521, "Pol P521", "p521@example.org", HashAlgorithm.SHA512), HashAlgorithm.SHA512),
}

# RSA key: also a signing subkey (subkey binding + embedded primary-key binding signature).
rsa = keys["rsa3072"][0]
sub = pgpy.PGPKey.new(PubKeyAlgorithm.RSAEncryptOrSign, 2048)
rsa.add_subkey(sub, usage={KeyFlags.Sign})

for name, (k, h) in keys.items():
    w(f"{name}.pub.asc", str(k.pubkey))
    sig = k.sign(MEMO, hash=h)
    w(f"memo.txt.{name}.sig", bytes(sig))            # binary detached
    w(f"memo.txt.{name}.asc", str(sig))              # armored detached

# RSA with SHA-512 (hash chosen by the signature) and the subkey's signature.
w("memo.txt.rsa3072-sha512.sig", bytes(rsa.sign(MEMO, hash=HashAlgorithm.SHA512)))
subkey = next(iter(rsa.subkeys.values()))
w("memo.txt.rsa3072-subkey.sig", bytes(subkey.sign(MEMO, hash=HashAlgorithm.SHA256)))

# Cleartext signed messages (dash-escaped line inside).
TEXT = "Dear all,\n-- this line starts with two dashes\nThe board meets on Monday.\n"
for name in ["rsa3072", "ed25519", "nistp256"]:
    k, h = keys[name]
    m = pgpy.PGPMessage.new(TEXT, cleartext=True)
    m |= k.sign(m, hash=h)
    w(f"clearsigned.{name}.asc", str(m))

# Inline signed (one-pass signature + literal data + signature), uncompressed and ZIP-compressed.
for name, comp in [("ed25519", CompressionAlgorithm.Uncompressed), ("rsa3072", CompressionAlgorithm.ZIP), ("nistp256", CompressionAlgorithm.ZLIB)]:
    k, h = keys[name]
    m = pgpy.PGPMessage.new(MEMO, compression=comp, file=False)
    m |= k.sign(m, hash=h)
    w(f"inline.{name}.gpg", bytes(m))
    w(f"inline.{name}.asc", str(m))

# Expired key: created 2020-01-01, expires one day later.
t0 = datetime(2020, 1, 1, tzinfo=timezone.utc)
exp = newkey(PubKeyAlgorithm.EdDSA, EllipticCurveOID.Ed25519, "Ex Pired", "expired@example.org", HashAlgorithm.SHA256,
             created=t0, expiry=timedelta(days=1))
w("expired.pub.asc", str(exp.pubkey))
w("memo.txt.expired-within.sig", bytes(exp.sign(MEMO, created=t0 + timedelta(hours=12))))
w("memo.txt.expired-after.sig", bytes(exp.sign(MEMO, created=t0 + timedelta(days=30))))

# Revoked key (superseded): one signature before the revocation, one after.
now = datetime.now(timezone.utc).replace(microsecond=0)
rev = newkey(PubKeyAlgorithm.EdDSA, EllipticCurveOID.Ed25519, "Re Voked", "revoked@example.org", HashAlgorithm.SHA256,
             created=now - timedelta(days=2))
w("memo.txt.revoked-before.sig", bytes(rev.sign(MEMO, created=now - timedelta(days=1))))
rsig = rev.revoke(rev, reason=RevocationReason.Superseded, comment="replaced by a new key", created=now - timedelta(hours=12))
w("memo.txt.revoked-after.sig", bytes(rev.sign(MEMO, created=now - timedelta(hours=1))))
pub = rev.pubkey
pub |= rsig
w("revoked.pub.asc", str(pub))

# PGP/MIME (RFC 3156): the signed entity is the first body part's exact CRLF bytes.
part = (b"Content-Type: text/plain; charset=utf-8\r\n"
        b"Content-Transfer-Encoding: quoted-printable\r\n"
        b"\r\n"
        b"The contract is attached in spirit.\r\n"
        b"Caf=C3=A9 meeting at 10.\r\n")
for name in ["ed25519", "rsa3072"]:
    k, h = keys[name]
    sig = k.sign(part, hash=h)
    msg = (b"From: Ed <ed@example.org>\r\n"
           b"To: Bob <bob@example.org>\r\n"
           b"Subject: PGP/MIME signed\r\n"
           b"Date: Sat, 07 Nov 2026 10:00:00 +0000\r\n"
           b"MIME-Version: 1.0\r\n"
           b"Content-Type: multipart/signed; micalg=pgp-sha256;\r\n"
           b" protocol=\"application/pgp-signature\"; boundary=\"=-sig-boundary-42\"\r\n"
           b"\r\n"
           b"This is an OpenPGP/MIME signed message (RFC 4880 and 3156)\r\n"
           b"--=-sig-boundary-42\r\n" + part + b"\r\n"
           b"--=-sig-boundary-42\r\n"
           b"Content-Type: application/pgp-signature; name=\"signature.asc\"\r\n"
           b"Content-Description: OpenPGP digital signature\r\n"
           b"\r\n" + str(sig).replace("\n", "\r\n").encode() + b"\r\n"
           b"--=-sig-boundary-42--\r\n")
    w(f"pgpmime.{name}.eml", msg)
