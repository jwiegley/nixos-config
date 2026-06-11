"""Nagios plugin: re-evaluate a Prometheus/Loki/VictoriaMetrics alert rule
expression through Nagios's own scheduler (Tier 2 of the Nagios <-> Prometheus
reverse mirror, docs/NAGIOS_PROMETHEUS_MIRROR_SPEC.md).

Reads a query file (the rule's expr verbatim, possibly a multi-line block
scalar), submits it to the instant-query API of the named datasource, and maps
a non-empty result vector to a Nagios exit code by severity:

    critical -> CRITICAL(2)   warning -> WARNING(1)   info -> OK(0, visibility)

An empty result vector -> OK(0). Any HTTP/parse failure -> UNKNOWN(3) after a
single 5s retry on a connection-level error (rides out a ruler restart during a
nixos-rebuild switch).

SECURITY: emits SERIES COUNTS ONLY. Never prints label values, metric names, or
any portion of the response body / query-result payload, and never logs the
expr. This is a loopback-only, unauthenticated query (existing posture).

stdlib only (urllib) so pkgs.writers.writePython3Bin needs no dependency
closure.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Nagios plugin exit codes.
STATE_OK = 0
STATE_WARNING = 1
STATE_CRITICAL = 2
STATE_UNKNOWN = 3

# Instant-query endpoints. Loki uses the LogQL instant-query path; a metric
# query (e.g. count_over_time(...)) returns resultType "vector" just like
# Prometheus/VM, so the result-vector logic below is uniform across all three.
ENDPOINTS = {
    "prometheus": "http://127.0.0.1:9090/api/v1/query",
    "loki": "http://127.0.0.1:3100/loki/api/v1/query",
    "vm": "http://127.0.0.1:8428/api/v1/query",
}

HTTP_TIMEOUT = 10  # seconds, per-request
RETRY_DELAY = 5  # seconds, single retry on a connection-level error


def query_once(url, expr):
    """Submit one instant query; return the parsed JSON dict.

    Raises urllib.error.URLError / json.JSONDecodeError / ValueError on
    failure so the caller can decide about retrying.
    """
    data = urllib.parse.urlencode({"query": expr}).encode("ascii")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        body = resp.read()
    return json.loads(body.decode("utf-8"))


def result_series_count(payload):
    """Count the series in a successful instant-query response.

    Returns an int (>= 0). Raises ValueError if the payload is not a
    success-status vector/matrix response (so the caller maps it to UNKNOWN).
    """
    if not isinstance(payload, dict):
        raise ValueError("response not an object")
    if payload.get("status") != "success":
        # Surface the API error type at most — never the message body.
        raise ValueError("query API status != success")
    data = payload.get("data") or {}
    result = data.get("result")
    if result is None:
        raise ValueError("response missing data.result")
    if not isinstance(result, list):
        raise ValueError("data.result not a list")
    return len(result)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Nagios plugin mirroring a Prometheus/Loki/VM alert rule",
    )
    parser.add_argument(
        "--datasource",
        required=True,
        choices=sorted(ENDPOINTS.keys()),
    )
    parser.add_argument("--query-file", required=True)
    parser.add_argument(
        "--severity",
        required=True,
        choices=["critical", "warning", "info"],
    )
    args = parser.parse_args(argv)

    url = ENDPOINTS[args.datasource]

    try:
        with open(args.query_file, "r", encoding="utf-8") as fh:
            expr = fh.read().strip()
    except OSError:
        # Do not echo the path's contents; the path itself is a store path
        # (public) so naming it is fine, but keep it terse.
        print("UNKNOWN: cannot read query file")
        return STATE_UNKNOWN

    if not expr:
        print("UNKNOWN: query file is empty")
        return STATE_UNKNOWN

    # One query, with a single 5s retry on a connection-level error only
    # (refused/reset/timeout). A clean HTTP response that fails to parse is a
    # real fault, not a transient restart, so it is not retried.
    payload = None
    last_kind = "error"
    for attempt in (0, 1):
        try:
            payload = query_once(url, expr)
            break
        except urllib.error.URLError as exc:
            # URLError covers connection-refused, reset, DNS, and socket
            # timeouts. reason may be an OSError or a string; never include
            # any server-provided body.
            last_kind = "connection error"
            reason = getattr(exc, "reason", None)
            if isinstance(reason, str) and reason:
                last_kind = "connection error"
            if attempt == 0:
                time.sleep(RETRY_DELAY)
                continue
        except (ValueError, json.JSONDecodeError):
            # Malformed JSON from a reachable endpoint: not transient.
            print("UNKNOWN: malformed response from %s API" % args.datasource)
            return STATE_UNKNOWN

    if payload is None:
        print(
            "UNKNOWN: %s API unreachable (%s) after retry" % (args.datasource, last_kind)
        )
        return STATE_UNKNOWN

    try:
        count = result_series_count(payload)
    except ValueError:
        print("UNKNOWN: %s API returned an error status" % args.datasource)
        return STATE_UNKNOWN

    perf = "|series=%d" % count

    if count == 0:
        print("OK: condition clear" + perf)
        return STATE_OK

    # Non-empty result vector -> the alert condition holds.
    if args.severity == "critical":
        print("CRITICAL: condition active: %d series" % count + perf)
        return STATE_CRITICAL
    if args.severity == "warning":
        print("WARNING: condition active: %d series" % count + perf)
        return STATE_WARNING
    # info severity never pages -- visibility only, OK exit.
    print("INFO condition active (visibility only): %d series" % count + perf)
    return STATE_OK


if __name__ == "__main__":
    sys.exit(main())
