"""CLI entry point. Subcommands: cross-check, backfill, detect."""
from __future__ import annotations

import argparse
import sys


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="flume-data")
    sub = parser.add_subparsers(dest="command", required=True)

    cross = sub.add_parser("cross-check", help="Phase 2 weekly cross-check")
    cross.add_argument("--days", type=int, default=7)

    back = sub.add_parser("backfill", help="Phase 3 historical backfill")
    back.add_argument("--from", dest="from_date")
    back.add_argument("--to", dest="to_date")
    back.add_argument("--discover", action="store_true")
    back.add_argument("--dry-run", action="store_true")
    back.add_argument("--promote", action="store_true")
    back.add_argument(
        "--unpromote",
        action="store_true",
        help=(
            "Remove backfilled stats from live LTS namespace (entire "
            "namespace — HA's recorder/clear_statistics is not range-"
            "filtered; --through is accepted for symmetry but ignored)."
        ),
    )
    back.add_argument(
        "--through",
        dest="through_date",
        help=(
            "Hour boundary for --promote. Accepted by --unpromote for "
            "CLI symmetry but ignored (clear_statistics wipes the entire "
            "namespace, not a range)."
        ),
    )
    back.add_argument(
        "--destinations",
        default="csv,vm,lts",
        help="Comma-separated subset of csv,vm,lts",
    )

    detect = sub.add_parser("detect", help="Bare detection over an input CSV")
    detect.add_argument("--input", required=True)

    args = parser.parse_args(argv)

    # Wire subcommands to their modules. cross-check and backfill are
    # implemented; `detect` is still a stub (detection.run_cli raises
    # NotImplementedError).
    if args.command == "cross-check":
        from . import cross_check
        return cross_check.run(days=args.days)
    if args.command == "backfill":
        from . import backfill
        return backfill.run(args)
    if args.command == "detect":
        from . import detection
        return detection.run_cli(input_path=args.input)
    return 2


if __name__ == "__main__":
    sys.exit(main())
