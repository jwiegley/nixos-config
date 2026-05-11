"""Unit tests for _parse_mcporter_output() and run_mcporter_list_via_ssh()."""

from __future__ import annotations

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
