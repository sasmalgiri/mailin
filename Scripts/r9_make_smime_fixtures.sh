#!/bin/zsh
# R9 (S/MIME half) — builds the synthetic S/MIME fixture set with OpenSSL.
# Owner permission 2026-11-09: a throwaway CA + recipient identities (.p12 with a known password)
# and signed, enveloped (RSA and EC) and signed-then-enveloped messages. Nothing here is a real
# identity; nothing is sent; no keychain is touched.
#
#   Scripts/r9_make_smime_fixtures.sh [<fixture root>]   (default ~/Downloads/Mail/Fixtures)
#
# Writes <root>/owner-pack/smime/ and refreshes <root>/owner-pack/SHA256SUMS. Every run makes new
# keys, so the digests change: re-run only together with updating ExternalFixtures' expectations
# (the tests read the identities and plaintext from the pack itself, so only SHA256SUMS changes).
set -euo pipefail
OPENSSL=${OPENSSL:-/opt/homebrew/bin/openssl}
ROOT=${1:-$HOME/Downloads/Mail/Fixtures}
PACK="$ROOT/owner-pack"
OUT="$PACK/smime"
PASS="mailin-fixture-2026"
rm -rf "$OUT"; mkdir -p "$OUT"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# --- Throwaway CA (RSA 2048, self-signed, 10 years) -------------------------------------------
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 3650 -sha256 \
  -subj "/O=mailin synthetic fixtures/CN=mailin R9 Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

leaf() {   # name keyspec cn email
  local name=$1 cn=$3 email=$4
  if [[ $2 == rsa ]]; then "$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $name.key 2>/dev/null
  else "$OPENSSL" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out $name.key 2>/dev/null; fi
  "$OPENSSL" req -new -key $name.key -out $name.csr -subj "/O=mailin synthetic fixtures/CN=$cn/emailAddress=$email"
  local ku="digitalSignature,keyEncipherment"; [[ $2 == ec ]] && ku="digitalSignature,keyAgreement"
  printf "basicConstraints=CA:FALSE\nkeyUsage=critical,%s\nextendedKeyUsage=emailProtection\nsubjectAltName=email:%s\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n" "$ku" "$email" > $name.ext
  "$OPENSSL" x509 -req -in $name.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -sha256 -extfile $name.ext -out $name.pem 2>/dev/null
  # PKCS#12 with the known password (OpenSSL 3 defaults: PBES2/AES-256-CBC, PBKDF2-SHA256, SHA-256 MAC).
  "$OPENSSL" pkcs12 -export -inkey $name.key -in $name.pem -certfile ca.pem -name "$cn" -passout pass:$PASS -out $name.p12
}
leaf alice rsa "Alice Archivist (R9 RSA)" alice@r9.mailin.example.invalid
leaf bob   ec  "Bob Recipient (R9 EC P-256)" bob@r9.mailin.example.invalid

# --- The plaintext MIME entity every message carries (CRLF, text + one attachment) -------------
python3 - <<'PY'
import base64
att = b"R9 ledger attachment\r\nline 2: synthetic, no personal data\r\n"
open("ledger.txt", "wb").write(att)
b64 = base64.encodebytes(att).decode().replace("\n", "\r\n")
body = ("Content-Type: multipart/mixed; boundary=\"R9-MIX\"\r\n\r\n"
        "--R9-MIX\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
        "The periwinkle ledger is sealed. R9 synthetic S/MIME fixture – Grüße.\r\n"
        "--R9-MIX\r\nContent-Type: text/plain; name=\"ledger.txt\"\r\nContent-Transfer-Encoding: base64\r\n"
        "Content-Disposition: attachment; filename=\"ledger.txt\"\r\n\r\n" + b64 +
        "--R9-MIX--\r\n")
open("entity.mime", "wb").write(body.encode("utf-8"))
PY

# --- Messages ---------------------------------------------------------------------------------
hdr() {   # file subject n
  printf "From: Alice Archivist <alice@r9.mailin.example.invalid>\r\nTo: Bob Recipient <bob@r9.mailin.example.invalid>\r\nSubject: %s\r\nDate: Mon, 09 Nov 2026 10:%02d:00 +0000\r\nMessage-ID: <r9-smime-%02d@mailin.example.invalid>\r\n" "$2" "$3" "$3" > "$1"
}
# OpenSSL 3.5 writes the base64 lines of -outform SMIME with bare LF even with -crlfeol; make every
# line CRLF (RFC 5322). The signed entity is already CRLF, so no signature is affected.
crlf() { python3 -c 'import sys;p=sys.argv[1];d=open(p,"rb").read().replace(b"\r\n",b"\n").replace(b"\n",b"\r\n");open(p,"wb").write(d)' "$1"; }
msg() {   # name subject n smime-file
  crlf "$4"; hdr "$OUT/$1.eml" "$2" "$3"; cat "$4" >> "$OUT/$1.eml"
}
C=( -crlfeol -binary )
"$OPENSSL" cms -sign "${C[@]}" -nodetach -in entity.mime -signer alice.pem -inkey alice.key -certfile ca.pem -outform SMIME -out s1.smime
msg signed-opaque-rsa "R9 signed (opaque, RSA)" 1 s1.smime
"$OPENSSL" cms -sign "${C[@]}" -in entity.mime -signer alice.pem -inkey alice.key -certfile ca.pem -outform SMIME -out s2.smime
msg signed-detached-rsa "R9 signed (multipart/signed, RSA)" 2 s2.smime   # also makes s2.smime CRLF before e3 wraps it
"$OPENSSL" cms -sign "${C[@]}" -nodetach -in entity.mime -signer bob.pem -inkey bob.key -certfile ca.pem -outform SMIME -out s3.smime
msg signed-opaque-ec "R9 signed (opaque, ECDSA P-256)" 3 s3.smime
"$OPENSSL" cms -encrypt "${C[@]}" -aes256 -in entity.mime -recip alice.pem -outform SMIME -out e1.smime
msg enveloped-rsa "R9 enveloped (RSA, AES-256-CBC)" 4 e1.smime
"$OPENSSL" cms -encrypt "${C[@]}" -aes256 -in entity.mime -recip bob.pem -keyopt ecdh_kdf_md:sha256 -outform SMIME -out e2.smime
msg enveloped-ec "R9 enveloped (ECDH P-256, AES-256-CBC)" 5 e2.smime
# Signed (multipart/signed by Alice), then that whole signed entity enveloped to Bob (EC) and Alice (RSA).
"$OPENSSL" cms -encrypt "${C[@]}" -aes-256-gcm -in s2.smime -recip alice.pem -recip bob.pem -outform SMIME -out e3.smime
msg signed-then-enveloped "R9 signed then enveloped (RSA + EC recipients, AES-256-GCM)" 6 e3.smime
# Tampered: the detached-signed message with one word of the signed text changed after signing.
hdr "$OUT/signed-detached-tampered.eml" "R9 signed, text altered after signing" 7
sed 's/periwinkle ledger/periwinkle LEDGER/' s2.smime >> "$OUT/signed-detached-tampered.eml"

cp ca.pem alice.pem bob.pem alice.p12 bob.p12 entity.mime ledger.txt "$OUT/"
# DER copies of the CMS parts (what the portable reader is handed), for tools that want them.
"$OPENSSL" cms -sign -binary -nodetach -in entity.mime -signer alice.pem -inkey alice.key -outform DER -out "$OUT/signed-opaque-rsa.p7m" 2>/dev/null
"$OPENSSL" cms -encrypt -binary -aes256 -in entity.mime -recip alice.pem -outform DER -out "$OUT/enveloped-rsa.p7m"
"$OPENSSL" cms -encrypt -binary -aes-128-gcm -in entity.mime -recip bob.pem -outform DER -out "$OUT/enveloped-ec-gcm.p7m"

# --- Self-check with OpenSSL before anything is listed ------------------------------------------
"$OPENSSL" cms -verify -CAfile ca.pem -in "$OUT/signed-opaque-rsa.eml" -out chk1 >/dev/null 2>&1 && cmp -s chk1 entity.mime
"$OPENSSL" cms -verify -CAfile ca.pem -in "$OUT/signed-detached-rsa.eml" -out chk2 >/dev/null 2>&1 && cmp -s chk2 entity.mime
"$OPENSSL" cms -verify -CAfile ca.pem -in "$OUT/signed-opaque-ec.eml" -out chk3 >/dev/null 2>&1 && cmp -s chk3 entity.mime
"$OPENSSL" cms -decrypt -in "$OUT/enveloped-rsa.eml" -recip alice.pem -inkey alice.key -out chk4 && cmp -s chk4 entity.mime
"$OPENSSL" cms -decrypt -in "$OUT/enveloped-ec.eml" -recip bob.pem -inkey bob.key -out chk5 && cmp -s chk5 entity.mime
"$OPENSSL" cms -decrypt -in "$OUT/signed-then-enveloped.eml" -recip bob.pem -inkey bob.key -out chk6
"$OPENSSL" cms -verify -CAfile ca.pem -in chk6 -out chk7 >/dev/null 2>&1 && cmp -s chk7 entity.mime
if "$OPENSSL" cms -verify -CAfile ca.pem -in "$OUT/signed-detached-tampered.eml" -out /dev/null >/dev/null 2>&1; then
  echo "tampered message verified — fixture is wrong" >&2; exit 1; fi
echo "OpenSSL self-check: 7 good rows verified/decrypted, tampered row rejected"
