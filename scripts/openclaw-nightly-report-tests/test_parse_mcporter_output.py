"""Unit tests for _parse_mcporter_output() and run_mcporter_list_via_ssh()."""

from __future__ import annotations

import subprocess
from unittest.mock import MagicMock

from conftest import load_report_module

report = load_report_module()


def test_parses_single_ok_server():
    stdout = "- searxng — SearXNG metasearch (2 tools, 0.6s)\n"
    result = report._parse_mcporter_output(stdout)
    assert "searxng" in result
    assert result["searxng"]["tool_count"] == 2
    assert result["searxng"]["status"].startswith("2 tools")


def test_parses_multiple_servers():
    stdout = (
        "- email-contacts — Email contacts (7 tools, 0.6s)\n"
        "- stock-trader — Stock trading (8 tools, 0.6s)\n"
        "- drafts — Drafts SSE bridge (1 tool, 0.8s)\n"
    )
    result = report._parse_mcporter_output(stdout)
    assert set(result) == {"email-contacts", "stock-trader", "drafts"}
    assert result["email-contacts"]["tool_count"] == 7
    assert result["drafts"]["tool_count"] == 1


def test_ignores_non_matching_lines():
    stdout = (
        "Listing MCP servers from /home/openclaw/.config/mcporter/mcp.json\n"
        "- vane — Vane (1 tool, 0.6s)\n"
        "\n"
    )
    result = report._parse_mcporter_output(stdout)
    assert set(result) == {"vane"}


def test_empty_input_returns_empty_dict():
    assert report._parse_mcporter_output("") == {}


def test_run_mcporter_list_via_ssh_returns_parsed_dict(monkeypatch):
    fake_stdout = (
        "- drafts — Drafts (1 tool, 0.5s)\n"
        "- home-assistant — HA bridge (12 tools, 0.7s)\n"
    )
    fake_proc = MagicMock(returncode=0, stdout=fake_stdout, stderr="")
    monkeypatch.setattr(subprocess, "run", MagicMock(return_value=fake_proc))
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_KEY", "/tmp/fake-key")
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_TARGET", "openclaw@10.99.0.2")
    result = report.run_mcporter_list_via_ssh()
    assert set(result) == {"drafts", "home-assistant"}
    assert result["home-assistant"]["tool_count"] == 12


def test_run_mcporter_list_via_ssh_missing_env_returns_empty(monkeypatch):
    monkeypatch.delenv("OPENCLAW_REPORT_SSH_KEY", raising=False)
    monkeypatch.delenv("OPENCLAW_REPORT_SSH_TARGET", raising=False)
    assert report.run_mcporter_list_via_ssh() == {}


def test_run_mcporter_list_via_ssh_returns_empty_on_timeout(monkeypatch):
    monkeypatch.setattr(
        subprocess,
        "run",
        MagicMock(side_effect=subprocess.TimeoutExpired("ssh", 60)),
    )
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_KEY", "/tmp/fake-key")
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_TARGET", "openclaw@10.99.0.2")
    assert report.run_mcporter_list_via_ssh() == {}


def test_run_mcporter_list_via_ssh_returns_empty_on_nonzero_exit(monkeypatch):
    fake_proc = MagicMock(returncode=255, stdout="", stderr="Permission denied")
    monkeypatch.setattr(subprocess, "run", MagicMock(return_value=fake_proc))
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_KEY", "/tmp/fake-key")
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_TARGET", "openclaw@10.99.0.2")
    assert report.run_mcporter_list_via_ssh() == {}
