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
        cwd="/etc/nixos.worktrees/water-attribution/scripts/flume-autofill",
    )
    assert result.returncode == 0
    assert "cross-check" in result.stdout
    assert "backfill" in result.stdout
