from __future__ import annotations
import os
from dataclasses import dataclass


def _read_file(path: str | None) -> str:
    if not path:
        return ""
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


def _parse_env_key(path: str | None, key: str) -> str:
    """Parse KEY=VALUE out of an env-style credential file (e.g. hermes/env)."""
    if not path:
        return ""
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith(f"{key}="):
                return line[len(key) + 1:].strip().strip('"').strip("'")
    return ""


@dataclass(frozen=True)
class Config:
    recipient: str
    sender: str
    sendmail: str
    dry_run: bool
    github_user: str
    github_org: str
    github_token: str
    gitea_url: str
    gitea_user: str
    gitea_token: str
    hermes_url: str
    hermes_model: str
    hermes_key: str
    state_db: str
    include_private: bool
    llm_token_budget: int
    stale_days: int

    @staticmethod
    def from_env() -> "Config":
        g = os.getenv
        return Config(
            recipient=g("OSS_SECRETARY_TO", "johnw@vulcan.lan"),
            sender=g("OSS_SECRETARY_FROM", "oss-secretary@vulcan.lan"),
            sendmail=g("OSS_SECRETARY_SENDMAIL", "/run/wrappers/bin/sendmail"),
            dry_run=bool(g("OSS_SECRETARY_DRY_RUN")),
            github_user=g("OSS_SECRETARY_GITHUB_USER", "jwiegley"),
            github_org=g("OSS_SECRETARY_GITHUB_ORG", "ledger"),
            github_token=_read_file(g("OSS_SECRETARY_GITHUB_TOKEN_FILE")),
            gitea_url=g("OSS_SECRETARY_GITEA_URL", "https://gitea.vulcan.lan/api/v1"),
            gitea_user=g("OSS_SECRETARY_GITEA_USER", "johnw"),
            gitea_token=_read_file(g("OSS_SECRETARY_GITEA_TOKEN_FILE")),
            hermes_url=g("OSS_SECRETARY_HERMES_URL",
                         "http://10.99.1.2:8080/v1/chat/completions"),
            hermes_model=g("OSS_SECRETARY_HERMES_MODEL",
                           "hera/omlx/Qwen3.6-27B-oQ4e-mtp"),
            hermes_key=_parse_env_key(g("OSS_SECRETARY_HERMES_ENV_FILE"), "API_SERVER_KEY"),
            state_db=g("OSS_SECRETARY_STATE_DB", "/var/lib/open-source-secretary/state.db"),
            include_private=bool(g("OSS_SECRETARY_INCLUDE_PRIVATE")),
            llm_token_budget=int(g("OSS_SECRETARY_LLM_TOKEN_BUDGET", "12000")),
            stale_days=int(g("OSS_SECRETARY_STALE_DAYS", "30")),
        )
