import os
from pathlib import Path
from oss_secretary.config import Config


def test_from_env_reads_credential_files(tmp_path, monkeypatch):
    gh = tmp_path / "gh"; gh.write_text("ghp_tokenvalue\n")
    gt = tmp_path / "gt"; gt.write_text("gitea_tokenvalue\n")
    henv = tmp_path / "hermes_env"
    henv.write_text("FOO=bar\nAPI_SERVER_KEY=secret-hermes-key\nBAZ=qux\n")
    monkeypatch.setenv("OSS_SECRETARY_GITHUB_TOKEN_FILE", str(gh))
    monkeypatch.setenv("OSS_SECRETARY_GITEA_TOKEN_FILE", str(gt))
    monkeypatch.setenv("OSS_SECRETARY_HERMES_ENV_FILE", str(henv))
    monkeypatch.setenv("OSS_SECRETARY_STATE_DB", str(tmp_path / "state.db"))
    cfg = Config.from_env()
    assert cfg.github_token == "ghp_tokenvalue"
    assert cfg.gitea_token == "gitea_tokenvalue"
    assert cfg.hermes_key == "secret-hermes-key"     # parsed out of the env file
    assert cfg.include_private is False               # default
    assert cfg.recipient == "johnw@vulcan.lan"
    assert cfg.llm_token_budget == 12000


def test_include_private_toggle(tmp_path, monkeypatch):
    for v in ("GITHUB_TOKEN_FILE", "GITEA_TOKEN_FILE", "HERMES_ENV_FILE"):
        f = tmp_path / v; f.write_text("API_SERVER_KEY=k\nx\n")
        monkeypatch.setenv(f"OSS_SECRETARY_{v}", str(f))
    monkeypatch.setenv("OSS_SECRETARY_INCLUDE_PRIVATE", "1")
    monkeypatch.setenv("OSS_SECRETARY_STATE_DB", str(tmp_path / "s.db"))
    assert Config.from_env().include_private is True
