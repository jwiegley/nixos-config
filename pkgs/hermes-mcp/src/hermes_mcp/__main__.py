"""CLI entrypoint — `python -m hermes_mcp` or `hermes-mcp` binary."""
import sys
from hermes_mcp import __version__


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("--version", "-V"):
        print(f"hermes-mcp {__version__}")
        return 0
    # Server entrypoint lands here in Task 6.
    from hermes_mcp.server import run
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
