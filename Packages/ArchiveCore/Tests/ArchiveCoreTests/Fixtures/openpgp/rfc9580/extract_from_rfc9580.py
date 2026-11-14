import sys
t = open('/tmp/pgpwork/rfc9580.txt').read()
F = sys.argv[1].rstrip('/') + '/'
def block(start_marker, begin, end):
    i = t.rindex(start_marker); j = t.index(begin, i); k = t.index(end, j) + len(end)
    lines = t[j:k].split('\n')
    return '\n'.join(l[3:] if l.startswith('   ') else l for l in lines) + '\n'
open(F + 'A1-v4-ed25519legacy.pub.asc', 'w').write(block('A.1.  Sample Version 4 Ed25519Legacy Key', '-----BEGIN PGP PUBLIC KEY BLOCK-----', '-----END PGP PUBLIC KEY BLOCK-----'))
open(F + 'A2-v4-ed25519legacy-OpenPGP.sig.asc', 'w').write(block('A.2.  Sample Version 4 Ed25519Legacy Signature', '-----BEGIN PGP SIGNATURE-----', '-----END PGP SIGNATURE-----'))
open(F + 'A3-v6-certificate.pub.asc', 'w').write(block('A.3.  Sample Version 6 Certificate', '-----BEGIN PGP PUBLIC KEY BLOCK-----', '-----END PGP PUBLIC KEY BLOCK-----'))
open(F + 'A6-cleartext-signed.asc', 'w').write(block('A.6.  Sample Cleartext Signed Message', '-----BEGIN PGP SIGNED MESSAGE-----', '-----END PGP SIGNATURE-----'))
open(F + 'A7-inline-signed.asc', 'w').write(block('A.7.  Sample Inline-Signed Message', '-----BEGIN PGP MESSAGE-----', '-----END PGP MESSAGE-----'))
