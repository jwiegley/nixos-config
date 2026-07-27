from __future__ import annotations
import re

# Redaction source of truth: REDACT_PATTERNS + redact() mirror
# scripts/agent_health_report.py:77-98 (same secret shapes as the self-heal
# grammars), extended for this collector because it ingests arbitrary
# third-party issue/PR/comment text where pasted credentials are common.
# Additions beyond the mirrored source: a real JWT catcher, AWS/Google/
# Perplexity key prefixes, GitHub PAT shapes, the Gitea `token <pat>` header
# form, and generic `scheme://user:pass@host` credential URLs. Over-redaction
# is always safe; under-redaction leaks (spec §10.1).
REDACT_PATTERNS = [
    # JWT: header.payload.signature (base64url); real tokens start `eyJ`.
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{6,}"),
    re.compile(r"sk-proj-[A-Za-z0-9_-]{6,}"),
    re.compile(r"sk-or-v1-[A-Za-z0-9_-]{6,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),                       # AWS access key id
    re.compile(r"AIza[0-9A-Za-z_\-]{35}"),                 # Google API key
    re.compile(r"pplx-[A-Za-z0-9]{20,}"),                  # Perplexity
    # GitHub tokens (classic PAT/OAuth/user/server/refresh) and fine-grained.
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{6,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{6,}"),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
    # Gitea-style `Authorization: token <pat>` (space-delimited, not `=`).
    re.compile(r"(?i)\btoken\s+[A-Za-z0-9._\-]{16,}"),
    # key=value secret shapes (superset of the documented leak forms).
    re.compile(
        r"(?i)(token|password|passwd|passphrase|api[_-]?key|secret|client_secret|"
        r"psk|refresh_token|access_token)=[^\s&\"]+"
    ),
    # E.164 phone number (PII — the 2026-05-18 SOPS leak shape).
    re.compile(r"(?<!\d)\+\d{10,15}(?!\d)"),
    # Pairing / registration / verification codes (the 2026-05-21 HomeKit shape).
    re.compile(r"(?i)\b(?:pairing|registration|verification)\s+code[:\s]+\S+"),
    # Credential-bearing URLs: postgres/mysql explicit, plus generic
    # scheme://user:pass@host (catches https://x-access-token:<t>@github.com/…).
    re.compile(r"(?i)(?:postgres(?:ql)?|mysql)://[^:@\s/]+:[^@\s]+@\S+"),
    re.compile(r"(?i)\b[a-z][a-z0-9+.\-]*://[^/\s:@]+:[^@\s/]+@"),
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
