import pytest
from oss_secretary.redact import redact

AIZA = "AIza" + "B" * 35
AKIA = "AKIA" + "IOSFODNN7EXAMPLE"          # 16 chars after AKIA
PPLX = "pplx-" + "a" * 24
JWT = ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0."
       "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")

# (raw text containing a secret, a distinctive substring that must be scrubbed)
CASES = [
    ("key sk-ant-api03-abcdef123456", "sk-ant-"),
    ("Authorization: Bearer ghp_0123456789abcdef0123456789abcdef0123", "ghp_0123"),
    ("db url postgres://user:s3cr3tpw@host:5432/db", "s3cr3tpw"),
    ("clone https://x-access-token:ghs_deadbeefcafebabe00@github.com/o/r", "ghs_deadbeef"),
    ("token=deadbeefcafebabe1234567890", "deadbeefcafebabe"),
    ("Authorization: token 1a2b3c4d5e6f7a8b9c0d1e2f", "1a2b3c4d5e6f"),
    ("call me at +14155552671 tomorrow", "+14155552671"),
    (f"google api key {AIZA} here", AIZA),
    (f"aws access key {AKIA} here", AKIA),
    (f"perplexity {PPLX} here", PPLX),
    (f"jwt {JWT} here", "eyJzdWIiOiIxMjM0NTY3ODkwIn0"),
    ("-----BEGIN PRIVATE KEY-----\nMIIEvQabc\n-----END PRIVATE KEY-----", "MIIEvQabc"),
]


@pytest.mark.parametrize("raw,needle", CASES)
def test_redact_scrubs_known_secret_shapes(raw, needle):
    assert needle not in redact(raw), f"{needle!r} leaked through redact()"


def test_redact_preserves_ordinary_text():
    assert redact("Segfault on startup in v3.2") == "Segfault on startup in v3.2"
