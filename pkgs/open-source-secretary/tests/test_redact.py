import pytest
from oss_secretary.redact import redact

SECRETS = [
    "here is my key sk-ant-api03-abcdef[REDACTED-TAIL]",
    "Authorization: Bearer ghp_0123456789abcdef0123456789abcdef0123",
    "db url postgres://user:s3cr3tpw@host:5432/db",
    "token=deadbeefcafebabe1234567890",
    "call me at +14155552671 tomorrow",
    "-----BEGIN PRIVATE KEY-----\nMIIEvQ...\n-----END PRIVATE KEY-----",
]


@pytest.mark.parametrize("raw", SECRETS)
def test_redact_scrubs_known_secret_shapes(raw):
    out = redact(raw)
    for needle in ["sk-ant-", "ghp_0123", "s3cr3tpw", "deadbeefcafebabe", "+14155552671", "MIIEvQ"]:
        assert needle not in out, f"{needle!r} leaked through redact()"


def test_redact_preserves_ordinary_text():
    assert redact("Segfault on startup in v3.2") == "Segfault on startup in v3.2"
