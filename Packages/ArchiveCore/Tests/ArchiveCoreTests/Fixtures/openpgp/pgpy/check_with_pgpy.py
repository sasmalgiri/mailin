import sys, os, warnings, glob
warnings.simplefilter("ignore")
import pgpy
d = sys.argv[1]
memo = open(os.path.join(d, "memo.txt"), "rb").read()
for f in sorted(glob.glob(os.path.join(d, "*.pub.asc"))):
    k, _ = pgpy.PGPKey.from_file(f)
    print(os.path.basename(f), k.fingerprint, [str(u.userid) for u in k.userids], [str(s.fingerprint) for s in k.subkeys.values()])
def key(n):
    return pgpy.PGPKey.from_file(os.path.join(d, n + ".pub.asc"))[0]
for n in ["rsa3072", "ed25519", "nistp256", "nistp384", "nistp521"]:
    s = pgpy.PGPSignature.from_blob(open(os.path.join(d, f"memo.txt.{n}.sig"), "rb").read())
    print(n, "detached", bool(key(n).verify(memo, s)))
for n in ["rsa3072", "ed25519", "nistp256"]:
    m = pgpy.PGPMessage.from_file(os.path.join(d, f"clearsigned.{n}.asc"))
    print(n, "clearsigned", bool(key(n).verify(m)))
    m = pgpy.PGPMessage.from_file(os.path.join(d, f"inline.{n}.asc"))
    print(n, "inline", bool(key(n).verify(m)))
s = pgpy.PGPSignature.from_blob(open(os.path.join(d, "memo.txt.rsa3072-subkey.sig"), "rb").read())
print("subkey", bool(key("rsa3072").verify(memo, s)))
