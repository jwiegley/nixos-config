#!/usr/bin/env python3
# Build-time fix for thinqconnect 1.0.13: replace its pyOpenSSL X509Req CSR
# generation (removed in pyOpenSSL >= 24.3.0; HA now ships 25.x/26.x) with the
# equivalent using the `cryptography` library. Line-ending-agnostic; asserts so
# the build fails loudly if upstream changes the block. See
# modules/services/home-assistant.nix / overlays/default.nix (haPackageOverrides).
import pathlib

p = pathlib.Path("thinqconnect/mqtt_client.py")
s = p.read_text()

s2 = s.replace(
    "from OpenSSL import crypto\n",
    "from cryptography import x509\n"
    "from cryptography.hazmat.primitives import hashes, serialization\n"
    "from cryptography.hazmat.primitives.asymmetric import rsa\n"
    "from cryptography.x509.oid import NameOID\n",
)
assert s2 != s, "thinqconnect x509 fix: 'from OpenSSL import crypto' anchor not found"
s = s2

old = '''        key = crypto.PKey()
        key.generate_key(crypto.TYPE_RSA, PRIVATE_KEY_SIZE)
        key_pem = crypto.dump_privatekey(crypto.FILETYPE_PEM, key).decode("utf-8")
        self.bytes_private_key = key_pem.encode("utf-8")

        csr = crypto.X509Req()
        csr.get_subject().CN = "lg_thinq"
        csr.set_pubkey(key)
        csr.sign(key, "sha512")

        csr_pem = crypto.dump_certificate_request(crypto.FILETYPE_PEM, csr).decode(encoding="utf-8")'''
new = '''        key = rsa.generate_private_key(public_exponent=65537, key_size=PRIVATE_KEY_SIZE)
        key_pem = key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ).decode("utf-8")
        self.bytes_private_key = key_pem.encode("utf-8")

        csr = (
            x509.CertificateSigningRequestBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "lg_thinq")]))
            .sign(key, hashes.SHA512())
        )
        csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode(encoding="utf-8")'''
assert old in s, "thinqconnect x509 fix: CSR block not found (upstream changed?)"
s = s.replace(old, new)
p.write_text(s)
print("thinqconnect x509 fix applied")
