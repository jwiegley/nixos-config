import subprocess
from unittest.mock import MagicMock

from conftest import load_report_module

m = load_report_module()









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
