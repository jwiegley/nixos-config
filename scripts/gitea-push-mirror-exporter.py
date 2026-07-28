"""Export Gitea push-mirror OUTCOME metrics to a node-exporter textfile.

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add
one here or flake8 flags it as E265 (it would land on line 2).

Why this exists
---------------
The nightly `sync-push-mirrors` job POSTs `push_mirrors-sync` per repo, which only
asks Gitea to *schedule* a push. Its shell loop treats a failed POST identically to
"this repo has no push mirrors configured" (both hit the same else branch, neither
increments a counter, and the script exits 0 either way). So on 2026-07-28 the
Gitea->GitHub mirror for nixos-config was found to have been failing every single
day since 2026-05-05 -- 678 commits behind, rejected by GitHub push protection --
while every systemd unit in the chain reported success. The only record anywhere was
an HTTP 500 in an nginx access log, which nothing alerts on.

This exporter reads the OUTCOME instead of the trigger: Gitea records the result of
the actual push attempt per mirror in `last_error` / `last_update`, so a mirror that
is rejected by the remote shows up here even though the scheduling call succeeded.

Metric semantics -- READ BEFORE WRITING RULES
---------------------------------------------
`last_update` is the last push ATTEMPT, not the last success. Measured 2026-07-28:
nixos-config reported last_update of 14:27 that same day while being 678 commits
behind and failing continuously since 2026-05-05. A freshness/staleness rule built on
this field is therefore WORTHLESS for detecting a broken mirror -- it looks healthy on
one that has never worked. It is exported only for "has this mirror ever been
attempted / has the scheduler stopped touching it entirely" questions.

`last_error` is the only trustworthy failure signal, and it is level-triggered: Gitea
sets it when the push is rejected and clears it on a later success. That is what
gitea_push_mirror_failed encodes and what GiteaPushMirrorFailing alerts on.

SECURITY
--------
A Gitea push mirror authenticates to its remote using credentials embedded in
`remote_address` (e.g. https://user:TOKEN@github.com/...), and `last_error` routinely
quotes that same URL back in git's error text. Neither field is ever emitted here --
not as a label, not as a log line. We export a boolean for failure and a timestamp
for freshness, and nothing else. `repo` and `remote_name` are safe identifiers.
Cardinality is bounded by the number of repos that actually have mirrors.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GITEA_URL = os.environ.get("GITEA_URL", "https://gitea.vulcan.lan")
GITEA_USER = os.environ.get("GITEA_USER", "johnw")
OUT = os.environ.get(
    "TEXTFILE_PATH",
    "/var/lib/prometheus-node-exporter-textfiles/gitea_push_mirror.prom",
)
TIMEOUT = int(os.environ.get("HTTP_TIMEOUT", "20"))


def _token() -> str:
    """Read the API token from the systemd credential directory only."""
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if not cred_dir:
        raise RuntimeError("CREDENTIALS_DIRECTORY unset; run me via systemd LoadCredential")
    with open(os.path.join(cred_dir, "gitea-token"), encoding="utf-8") as fh:
        return fh.read().strip()


def _get(path: str, token: str):
    req = urllib.request.Request(
        f"{GITEA_URL}{path}", headers={"Authorization": f"token {token}"}
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.load(resp)


def _repos(token: str):
    """All repo names owned by GITEA_USER, following pagination."""
    page = 1
    while True:
        q = urllib.parse.urlencode({"owner": GITEA_USER, "limit": 50, "page": page})
        data = _get(f"/api/v1/repos/search?{q}", token).get("data") or []
        if not data:
            return
        for repo in data:
            yield repo["name"]
        page += 1


def _parse_ts(value) -> float:
    """Gitea emits RFC3339. Return epoch seconds, or 0.0 if absent/unparseable."""
    if not value:
        return 0.0
    try:
        text = value.replace("Z", "+00:00")
        return time.mktime(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return 0.0


def main() -> int:
    lines = [
        "# HELP gitea_push_mirror_failed Whether the last push to this mirror's remote failed (1) or not (0).",
        "# TYPE gitea_push_mirror_failed gauge",
        "# HELP gitea_push_mirror_last_update_timestamp_seconds Epoch of the last push ATTEMPT (NOT success) for this mirror; 0 if never.",
        "# TYPE gitea_push_mirror_last_update_timestamp_seconds gauge",
        "# HELP gitea_push_mirror_scrape_success Whether this exporter completed a full pass.",
        "# TYPE gitea_push_mirror_scrape_success gauge",
        "# HELP gitea_push_mirror_scrape_timestamp_seconds Epoch when this exporter last completed.",
        "# TYPE gitea_push_mirror_scrape_timestamp_seconds gauge",
        "# HELP gitea_push_mirror_count Number of configured push mirrors discovered.",
        "# TYPE gitea_push_mirror_count gauge",
        "# HELP gitea_push_mirror_failed_count Number of push mirrors whose last push failed.",
        "# TYPE gitea_push_mirror_failed_count gauge",
    ]

    total = 0
    failed = 0
    ok = 1
    try:
        token = _token()
        for repo in _repos(token):
            try:
                mirrors = _get(
                    f"/api/v1/repos/{GITEA_USER}/{urllib.parse.quote(repo)}/push_mirrors",
                    token,
                )
            except urllib.error.HTTPError as exc:
                # 404 simply means "no push mirrors on this repo" -- not a failure.
                if exc.code == 404:
                    continue
                ok = 0
                continue
            for mirror in mirrors or []:
                total += 1
                # NEVER emit remote_address or last_error text: both can embed the
                # remote's auth token. A boolean is all the alert needs.
                is_failed = 1 if (mirror.get("last_error") or "").strip() else 0
                failed += is_failed
                remote = (mirror.get("remote_name") or "unknown").replace('"', "")
                safe_repo = repo.replace('"', "")
                labels = f'repo="{safe_repo}",remote_name="{remote}"'
                lines.append(f"gitea_push_mirror_failed{{{labels}}} {is_failed}")
                lines.append(
                    "gitea_push_mirror_last_update_timestamp_seconds"
                    f"{{{labels}}} {_parse_ts(mirror.get('last_update')):.0f}"
                )
    except Exception as exc:  # noqa: BLE001 - exporter must always emit something
        ok = 0
        print(f"gitea-push-mirror-exporter: {type(exc).__name__}", file=sys.stderr)

    lines.append(f"gitea_push_mirror_count {total}")
    lines.append(f"gitea_push_mirror_failed_count {failed}")
    lines.append(f"gitea_push_mirror_scrape_success {ok}")
    lines.append(f"gitea_push_mirror_scrape_timestamp_seconds {time.time():.0f}")

    tmp = f"{OUT}.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT)  # atomic; avoids the half-written .prom files seen elsewhere
    os.chmod(OUT, 0o644)  # metrics only, no secrets -- node-exporter must read it

    # Exit non-zero on a partial pass so the unit fails loudly rather than
    # publishing a confidently-wrong zero. This is the exact failure mode being
    # fixed: a job that exits 0 having done nothing.
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
