"""Intrinsic properties of the self-heal action and aux scripts.

DISCOVERS the scripts rather than listing them. An earlier version pinned the
exact directory contents in EXPECTED_ACTIONS/EXPECTED_AUX and parametrized
everything over those sets, so adding or renaming an action meant editing this
file too. Nothing here should have an opinion about WHICH scripts exist -- only
that whatever does exist is runnable the way the daemon runs it.

Also removed: a smoke test that ran every action with a fake `systemctl` placed
on PATH. The mock never worked -- the actions invoke
/run/current-system/sw/bin/systemctl by absolute path, exactly as
test_script_has_absolute_shebang below requires, and PATH cannot shadow an
absolute path. So on a live host it invoked the REAL remediations: restarting
microvm@hermes, hermes-mcp and hermes-prepare-secrets, and deleting Hermes'
auth.json. It appeared to pass only because restart_microvm's upstream preflight
was declining; once the gateway was healthy the same test began timing out at its
10s budget mid-preflight, and with a longer budget it would have restarted the VM.
For all that, it asserted only that some JSON was emitted.
"""
import pathlib
import stat

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTIONS_DIR = ROOT / "actions"
AUX_DIR = ROOT / "aux"

# Absolute, because sudo strips PATH.
REQUIRED_SHEBANG = "#!/run/current-system/sw/bin/bash"


def _scripts():
    found = []
    for d in (ACTIONS_DIR, AUX_DIR):
        if d.is_dir():
            found += [p for p in sorted(d.iterdir()) if p.is_file()]
    return found


_SCRIPTS = _scripts()
_IDS = [f"{p.parent.name}/{p.name}" for p in _SCRIPTS]


def test_some_scripts_were_discovered():
    """Guard against the glob matching nothing, which would make every
    parametrized test below vacuously pass."""
    assert _SCRIPTS, f"no scripts found under {ACTIONS_DIR} or {AUX_DIR}"


@pytest.mark.parametrize("script", _SCRIPTS, ids=_IDS)
def test_script_is_executable(script):
    assert script.stat().st_mode & stat.S_IXUSR, f"{script} is not executable"


@pytest.mark.parametrize("script", _SCRIPTS, ids=_IDS)
def test_script_has_absolute_shebang(script):
    """sudo strips PATH, so `#!/usr/bin/env bash` fails when the daemon runs it."""
    first = script.read_text().splitlines()[0]
    assert first == REQUIRED_SHEBANG, f"{script.name} has shebang {first!r}"
