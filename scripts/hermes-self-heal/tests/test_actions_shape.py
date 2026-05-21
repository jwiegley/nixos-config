"""Action + aux script shape tests.

Verifies every script is executable, has the correct shebang, and
(for actions) prints valid JSON on a smoke invocation. Real systemctl
calls are mocked via a PATH override that places a fake systemctl
first.
"""
import os
import json
import pathlib
import stat
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTIONS_DIR = ROOT / "actions"
AUX_DIR = ROOT / "aux"
EXPECTED_ACTIONS = {
    "restart_microvm",
    "restart_mcp",
    "restage_secrets",
    "reset_credential_pool",
    "restart_health_check",
}
EXPECTED_AUX = {"read_log_tail", "kick_health_check"}


def test_actions_dir_has_exactly_expected_scripts():
    actual = {p.name for p in ACTIONS_DIR.iterdir() if p.is_file()}
    assert actual == EXPECTED_ACTIONS


def test_aux_dir_has_exactly_expected_scripts():
    actual = {p.name for p in AUX_DIR.iterdir() if p.is_file()}
    assert actual == EXPECTED_AUX


@pytest.mark.parametrize("name", sorted(EXPECTED_ACTIONS | EXPECTED_AUX))
def test_script_is_executable(name):
    p = ACTIONS_DIR / name if name in EXPECTED_ACTIONS else AUX_DIR / name
    mode = p.stat().st_mode
    assert mode & stat.S_IXUSR, f"{p} not executable"


@pytest.mark.parametrize("name", sorted(EXPECTED_ACTIONS | EXPECTED_AUX))
def test_script_has_absolute_shebang(name):
    """Sudo strips PATH; /usr/bin/env bash will fail."""
    p = ACTIONS_DIR / name if name in EXPECTED_ACTIONS else AUX_DIR / name
    first = p.read_text().splitlines()[0]
    assert first == "#!/run/current-system/sw/bin/bash", \
        f"{name} has wrong shebang: {first!r}"


@pytest.mark.parametrize("name", sorted(EXPECTED_ACTIONS))
def test_action_prints_valid_json_with_fake_systemctl(name, tmp_path):
    """Smoke test: run each action with a fake systemctl on PATH.
    Asserts the script emits valid JSON on its last stdout line.

    Skipped at flake-check time because /run/current-system doesn't
    exist in the sandbox; runs locally when invoked directly.
    Note: reset_credential_pool also needs realpath from /run/current-system.
    """
    if not pathlib.Path("/run/current-system/sw/bin/bash").exists():
        pytest.skip("Not running on the live system; /run/current-system absent")

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "systemctl").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "systemctl").chmod(0o755)
    (fake_bin / "rm").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "rm").chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    result = subprocess.run(
        [str(ACTIONS_DIR / name)],
        env=env, capture_output=True, text=True, timeout=10,
    )
    last_line = result.stdout.strip().splitlines()[-1]
    parsed = json.loads(last_line)
    assert "ok" in parsed
