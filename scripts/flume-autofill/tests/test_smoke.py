from pathlib import Path


# Package root directory (parent of the tests/ directory). Derived from
# __file__ so the test still works after the worktree is merged to main.
ROOT = Path(__file__).resolve().parents[1]


def test_package_imports():
    """flume_autofill imports cleanly."""
    import flume_autofill
    assert flume_autofill.__version__ == "0.1.0"


def test_cli_help_works():
    """The CLI parser accepts --help without crashing."""
    import subprocess, sys
    result = subprocess.run(
        [sys.executable, "-m", "flume_autofill", "--help"],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
    )
    assert result.returncode == 0
    assert "cross-check" in result.stdout
    assert "backfill" in result.stdout
