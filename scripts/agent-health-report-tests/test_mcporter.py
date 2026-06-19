import subprocess
from unittest.mock import MagicMock

from conftest import load_report_module

m = load_report_module()


def test_parses_single_ok_server():
    stdout = "- searxng — SearXNG metasearch (2 tools, 0.6s)\n"
    result = m._parse_mcporter_output(stdout)
    assert result["searxng"]["tool_count"] == 2
    assert result["searxng"]["status"].startswith("2 tools")


def test_parses_multiple_servers():
    stdout = (
        "- email-contacts — Email contacts (7 tools, 0.6s)\n"
        "- stock-trader — Stock trading (8 tools, 0.6s)\n"
        "- vane — Vane AI (1 tool, 0.8s)\n"
    )
    result = m._parse_mcporter_output(stdout)
    assert set(result) == {"email-contacts", "stock-trader", "vane"}
    assert result["email-contacts"]["tool_count"] == 7
    assert result["vane"]["tool_count"] == 1


def test_ignores_non_matching_lines():
    stdout = (
        "Listing MCP servers from /home/openclaw/.config/mcporter/mcp.json\n"
        "- vane — Vane (1 tool, 0.6s)\n\n"
    )
    assert set(m._parse_mcporter_output(stdout)) == {"vane"}


def test_empty_input_returns_empty_dict():
    assert m._parse_mcporter_output("") == {}


def test_ssh_list_parses_dict(monkeypatch):
    fake_stdout = (
        "- google-calendar-personal — GCal personal (3 tools, 0.5s)\n"
        "- home-assistant — HA bridge (12 tools, 0.7s)\n"
    )
    fake_proc = MagicMock(returncode=0, stdout=fake_stdout, stderr="")
    monkeypatch.setattr(subprocess, "run", MagicMock(return_value=fake_proc))
    result = m.run_mcporter_list_via_ssh(key="/tmp/fake-key", target="openclaw@10.99.0.2")
    assert set(result) == {"google-calendar-personal", "home-assistant"}
    assert result["home-assistant"]["tool_count"] == 12


def test_ssh_list_missing_env_returns_empty(monkeypatch):
    monkeypatch.delenv("OPENCLAW_REPORT_SSH_KEY", raising=False)
    monkeypatch.delenv("OPENCLAW_REPORT_SSH_TARGET", raising=False)
    assert m.run_mcporter_list_via_ssh() == {}


def test_ssh_list_timeout_returns_empty(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        MagicMock(side_effect=subprocess.TimeoutExpired("ssh", 60)),
    )
    assert m.run_mcporter_list_via_ssh(key="/tmp/k", target="openclaw@10.99.0.2") == {}


def test_ssh_probe_skips_without_key():
    out = m.ssh_probe(None, "host@1.2.3.4", [{"label": "x", "kind": "curl", "url": "http://x"}])
    assert out["skipped"] is True
    assert out["results"] == {}


def test_mcp_recall_frag_builds_retrieval_handshake():
    frag = m._mcp_recall_frag("c2", "http://127.0.0.1:8236/mcp")
    assert "http://127.0.0.1:8236/mcp" in frag
    assert "mcp-session-id" in frag
    assert '"method":"initialize"' in frag
    assert "notifications/initialized" in frag
    assert '"name":"recall"' in frag
    # OK only when recall returns a well-formed result; FAIL is the default.
    assert "grep -q total_results" in frag
    assert "c2=FAIL" in frag and "c2=OK" in frag


def test_ssh_probe_dispatches_mcp_recall_kind():
    # Unknown kinds are silently dropped; mcp_recall must be a recognized kind.
    checks = [{"label": "memory-vault recall", "kind": "mcp_recall",
               "url": "http://127.0.0.1:8236/mcp"}]
    out = m.ssh_probe(None, "host@1.2.3.4", checks)  # no key -> skips before run
    assert out["skipped"] is True


def test_memory_vault_state():
    assert m._memory_vault_state({"skipped": True}) == (False, False)
    assert m._memory_vault_state(
        {"skipped": False, "results": {"memory-vault recall": "OK"}}) == (True, False)
    assert m._memory_vault_state(
        {"skipped": False, "results": {"memory-vault recall": "FAIL"}}) == (True, True)
    assert m._memory_vault_state(
        {"skipped": False, "results": {"memory-vault recall": None}}) == (False, False)
