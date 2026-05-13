"""Env-driven runtime config for hermes-mcp."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    hermes_api_url: str         # e.g. http://10.99.1.2:8080
    hermes_api_key: str         # Authorization: Bearer ${this} (Hermes API_SERVER_KEY, sourced from API_SERVER_KEY env var)
    model: str                  # default model to use, e.g. hera/omlx/Qwen3.6-27B-MLX-8bit
    db_path: Path
    sse_host: str               # e.g. 127.0.0.1
    sse_port: int               # e.g. 9081
    request_timeout_seconds: float = 600.0

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            hermes_api_url=_required("HERMES_API_URL").rstrip("/"),
            hermes_api_key=_required("API_SERVER_KEY"),
            model=os.environ.get("HERMES_MCP_MODEL", "hera/omlx/Qwen3.6-27B-MLX-8bit"),
            db_path=Path(os.environ.get("HERMES_MCP_DB_PATH", "/var/lib/hermes-mcp/sessions.db")),
            sse_host=os.environ.get("HERMES_MCP_HOST", "127.0.0.1"),
            sse_port=int(os.environ.get("HERMES_MCP_PORT", "9081")),
            request_timeout_seconds=float(os.environ.get("HERMES_MCP_TIMEOUT", "600")),
        )


def _required(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        raise RuntimeError(f"required env var {name} is not set")
    return v
