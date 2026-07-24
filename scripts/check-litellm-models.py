#!/usr/bin/env python3
"""Validate that the LiteLLM model catalog agrees with the live hera/clio model
servers.

This is an ON-DEMAND check (run via `nix run .#check-litellm-models`, by hand,
or from a pre-commit / CI hook). It is deliberately NOT run at Nix evaluation
time: querying the servers over the network at eval would either require
import-from-derivation or couple every `nixos-rebuild` to the servers' uptime
(a rebuild would fail whenever hera/clio were offline). Keeping it on-demand
leaves evaluation pure and rebuilds independent of the model backends.

For every credential in litellm-settings.nix whose api_base points at a local
model server (hera.lan / clio.lan), it fetches that server's /v1/models and
compares against the model_list entries routed to that credential:

  (a) models the server offers that have NO LiteLLM entry routed via this
      credential — reported as a WARNING by default (a server commonly offers
      models you intentionally don't expose, or expose via a different
      credential), escalated to a failure with --strict;
  (b) LiteLLM entries whose model is NOT offered by the server it routes to —
      always a hard failure (broken routing).

Exit codes: 0 = in sync (modulo (a) warnings); 1 = drift ((b), or (a) under
--strict); 2 = a server was unreachable (could not validate) and nothing worse.
Model ids are not secrets; the servers are queried with a dummy bearer token
exactly as a client would.
"""

import argparse
import json
import os
import ssl
import subprocess
import sys
import urllib.request
from urllib.error import URLError

LOCAL_HOSTS = ("hera.lan", "clio.lan")


def eval_settings(settings_path):
    """Evaluate litellm-settings.nix with a stub mkSecret (no secrets needed —
    we only read model_list/credential_list) and return it as a dict."""
    expr = f'import {settings_path} {{ mkSecret = n: "STUB"; }}'
    # --impure: the expr imports litellm-settings.nix by absolute path, which
    # pure evaluation mode forbids. This is a read-only local eval (no network,
    # no derivation build), so impurity here is benign.
    proc = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expr],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"ERROR: `nix eval` of {settings_path} failed:\n{proc.stderr}")
    return json.loads(proc.stdout)


def fetch_model_ids(api_base, timeout):
    """Return the set of model ids from an OpenAI-compatible /v1/models
    endpoint. TLS verification is disabled: these are LAN servers behind a
    private CA, and only non-secret model-id metadata is read."""
    url = api_base.rstrip("/") + "/models"
    req = urllib.request.Request(url, headers={"Authorization": "Bearer dummy-key"})
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        data = json.load(resp)
    return {m["id"] for m in data.get("data", [])}


def server_side_id(litellm_model):
    """litellm_params.model is "<provider>/<server-id>"; strip the leading
    provider component (e.g. "openai/"). Server ids may themselves contain
    slashes (e.g. "GreenBitAI/Llama-2-13B-..."), so split only once."""
    return litellm_model.split("/", 1)[1] if "/" in litellm_model else litellm_model


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_settings = os.path.abspath(
        os.path.join(here, "..", "modules", "services", "litellm-settings.nix")
    )
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--settings",
        default=default_settings,
        help="path to litellm-settings.nix (default: %(default)s)",
    )
    ap.add_argument("--timeout", type=int, default=10, help="per-server HTTP timeout (s)")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="treat (a) server-model-not-in-config as a failure, not a warning",
    )
    args = ap.parse_args()

    cfg = eval_settings(args.settings)

    api_base_of = {
        c["credential_name"]: c.get("credential_values", {}).get("api_base")
        for c in cfg["credential_list"]
    }
    local_creds = {
        name: base
        for name, base in api_base_of.items()
        if base and any(host in base for host in LOCAL_HOSTS)
    }

    configured = {}  # credential -> set of server-side model ids
    for m in cfg["model_list"]:
        lp = m.get("litellm_params", {})
        cred = lp.get("litellm_credential_name")
        if cred in local_creds and "model" in lp:
            configured.setdefault(cred, set()).add(server_side_id(lp["model"]))

    drift = False  # (b), or (a) under --strict — hard failure
    warned = False  # (a) without --strict
    unreachable = []
    for cred, base in sorted(local_creds.items()):
        try:
            server_ids = fetch_model_ids(base, args.timeout)
        except (URLError, OSError, ValueError, KeyError) as exc:
            unreachable.append((cred, base, exc))
            continue
        cfg_ids = configured.get(cred, set())
        missing_from_cfg = server_ids - cfg_ids  # (a)
        missing_from_srv = cfg_ids - server_ids  # (b)
        print(f"\n=== {cred}  ({base}) ===")
        print(f"    server offers {len(server_ids)}, config maps {len(cfg_ids)}")
        if missing_from_cfg:
            label = "FAIL" if args.strict else "warn"
            if args.strict:
                drift = True
            else:
                warned = True
            print(f"  (a) [{label}] on server, no LiteLLM entry via this credential "
                  f"({len(missing_from_cfg)}):")
            for x in sorted(missing_from_cfg):
                print(f"        {x}")
        if missing_from_srv:
            drift = True
            print(f"  (b) [FAIL] in LiteLLM config, NOT offered by server "
                  f"({len(missing_from_srv)}):")
            for x in sorted(missing_from_srv):
                print(f"        {x}")
        if not missing_from_cfg and not missing_from_srv:
            print("    ✓ in sync")

    if unreachable:
        print("\n=== UNREACHABLE (could not validate) ===")
        for cred, base, exc in unreachable:
            print(f"    {cred} ({base}): {exc}")

    print()
    if drift:
        print("RESULT: DRIFT DETECTED (see [FAIL] lines above)")
        sys.exit(1)
    if unreachable:
        print("RESULT: INCOMPLETE — some servers were unreachable")
        sys.exit(2)
    if warned:
        print("RESULT: routing OK; (a) warnings above are informational "
              "(re-run with --strict to enforce)")
        sys.exit(0)
    print("RESULT: all local servers in sync with the LiteLLM config")
    sys.exit(0)


if __name__ == "__main__":
    main()
