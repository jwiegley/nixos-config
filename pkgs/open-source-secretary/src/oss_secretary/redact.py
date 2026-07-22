from __future__ import annotations
import re

# Redaction source of truth: REDACT_PATTERNS + redact() mirror
# scripts/agent_health_report.py:70-91 (same secret shapes as the self-heal
# grammars). Two extra shapes are appended per the plan: a postgres/mysql
# credential URL and a PEM private-key block. The sk-* minimum-length
# quantifier is relaxed from {20,} to {6,}: the literal prefixes are already
# highly specific (no false positives in prose), and over-redaction is always
# safe while under-redaction leaks.
REDACT_PATTERNS = [
    re.compile(r"[A-Za-z0-9_-]{24,40}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{6,}"),
    re.compile(r"sk-proj-[A-Za-z0-9_-]{6,}"),
    re.compile(r"sk-or-v1-[A-Za-z0-9_-]{6,}"),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
    # key=value secret shapes (superset of the documented leak forms).
    re.compile(
        r"(?i)(token|password|passwd|passphrase|api[_-]?key|secret|client_secret|"
        r"psk|refresh_token|access_token)=[^\s&\"]+"
    ),
    # E.164 phone number (PII — the 2026-05-18 SOPS leak shape).
    re.compile(r"(?<!\d)\+\d{10,15}(?!\d)"),
    # Pairing / registration / verification codes (the 2026-05-21 HomeKit shape).
    re.compile(r"(?i)\b(?:pairing|registration|verification)\s+code[:\s]+\S+"),
    # postgres/mysql connection URLs with an embedded password.
    re.compile(r"(?i)(?:postgres(?:ql)?|mysql)://[^:@\s/]+:[^@\s]+@\S+"),
    # PEM private-key blocks (any key type).
    re.compile(
        r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----",
        re.DOTALL,
    ),
]


def redact(s: str) -> str:
    for p in REDACT_PATTERNS:
        s = p.sub("[REDACTED]", s)
    return s
