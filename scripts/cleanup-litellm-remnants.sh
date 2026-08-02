#!/usr/bin/env bash
# Remove the on-disk remnants of the LiteLLM proxy, which was deleted from the
# NixOS configuration on 2026-08-01 and replaced by an nginx gateway on
# 127.0.0.1:4000 (modules/services/hera-llm-proxy.nix).
#
# NOTHING HERE RUNS AUTOMATICALLY. The operator asked for these files to be
# left in place for review, so this script is deliberately not wired into any
# module, timer, or activation script. Run it by hand, once you are satisfied
# the gateway has fully replaced what LiteLLM was doing.
#
#   ./cleanup-litellm-remnants.sh            # dry run — prints, deletes nothing
#   ./cleanup-litellm-remnants.sh --commit   # actually delete
#
# The PostgreSQL database is the one item worth pausing over: it holds the
# historical LiteLLM_SpendLogs (per-request token accounting). If you want to
# keep that history, dump it before dropping.

set -euo pipefail

COMMIT=0
[[ "${1:-}" == "--commit" ]] && COMMIT=1

run() {
  if (( COMMIT )); then
    echo "  RUN: $*"
    "$@"
  else
    echo "  WOULD RUN: $*"
  fi
}

note() { printf '\n== %s ==\n' "$1"; }

if (( ! COMMIT )); then
  echo "DRY RUN — nothing will be deleted. Re-run with --commit to apply."
fi

note "Preconditions"
if systemctl is-active --quiet nginx && curl -sf -o /dev/null --max-time 10 http://127.0.0.1:4000/v1/models; then
  echo "  OK: the replacement gateway on :4000 is answering."
else
  echo "  REFUSING: the gateway on 127.0.0.1:4000 is not answering /v1/models."
  echo "  Fix that first — otherwise you are deleting the old thing while the"
  echo "  new thing is down."
  exit 1
fi

for unit in litellm redis-litellm litellm-anthropic-fixup litellm-exporter \
            postgresql-litellm-optimize home-manager-litellm; do
  if systemctl cat "$unit.service" >/dev/null 2>&1; then
    echo "  WARNING: $unit.service still exists — did the switch actually apply?"
  fi
done

note "1. Rootless container state and images (user 'litellm')"
# The user's own podman store. Removing the user's home removes the images too,
# but do it explicitly first so the reclaimed space is visible.
if id litellm >/dev/null 2>&1; then
  run sudo -u litellm XDG_RUNTIME_DIR="/run/user/$(id -u litellm)" podman system reset --force
else
  echo "  user 'litellm' already gone — skipping podman reset"
fi

note "2. systemd linger"
# users.users.<n>.linger = true was declared, but this host runs
# mutableUsers = true, so DELETING the declaration does NOT revoke the linger.
# The file below persists and lets logind start a user manager at boot.
run sudo loginctl disable-linger litellm
run sudo rm -f /var/lib/systemd/linger/litellm

note "3. Filesystem state"
run sudo rm -rf /var/lib/containers/litellm     # rootless home (podman store)
run sudo rm -rf /var/lib/litellm                # ~183 MB, 7309 files
run sudo rm -rf /etc/litellm                    # rendered config.yaml + guardrail
run sudo rm -rf /run/secrets-litellm

note "4. TLS certificate for the retired vhost"
# Left in place these would keep being globbed by the certificate exporter and
# eventually raise an expiry alert for a hostname that no longer resolves.
run sudo rm -f /var/lib/nginx-certs/litellm.vulcan.lan.crt
run sudo rm -f /var/lib/nginx-certs/litellm.vulcan.lan.key

note "5. Stale textfile-collector metrics"
# ALREADY DONE 2026-08-02 -- kept here so the script stays a complete record.
#
# node_exporter serves whatever .prom files sit in this directory, forever, with
# no writer required. After the exporter was deleted, litellm.prom kept
# publishing litellm_availability=0 -- a metric asserting the service was DOWN,
# for a service that no longer existed. It was removed by hand along with the
# equally orphaned nagios_mirror_divergence.prom.
#
# NOTE THE PATH. This line previously read "…-text-files" (hyphenated), which
# does not exist, so it would have silently removed nothing while reporting
# success. Every other reference in the repo uses the unhyphenated form below.
run sudo rm -f /var/lib/prometheus-node-exporter-textfiles/litellm.prom

note "6. PostgreSQL database and role"
echo "  The 'litellm' database holds LiteLLM_SpendLogs (request/token history)."
echo "  Dump it first if you want to keep that:"
echo "    sudo -u postgres pg_dump -Fc litellm > /tank/Backups/Machines/Vulcan/litellm-\$(date +%F).dump"
run sudo -u postgres dropdb --if-exists litellm
run sudo -u postgres dropuser --if-exists litellm

note "7. UNIX user and group"
run sudo userdel -r litellm
run sudo groupdel litellm

note "8. SOPS entries — MANUAL, not scripted"
cat <<'EOF'
  These are NOT touched here: editing secrets.yaml requires an interactive
  `sops` session, and this script must never decrypt anything.

  Still referenced by the running configuration (do NOT delete):
    litellm/omlx-api-key   -> the gateway's upstream key
                              (hera-llm-proxy.nix, as sops.secrets."hera-llm-api-key")
    litellm-vulcan-lan     -> still gates rspamd's gpt.conf write, and is read
                              by vane and both self-heal daemons

  Safe to delete once you are sure nothing else wants them — every one of these
  was a hosted-provider key used only by the deleted model catalog:
    litellm/api-key                   litellm/anthropic-api-key
    litellm/gemini-api-key            litellm/openai-api-key
    litellm/perplexityai-api-key      litellm/groq-api-key
    litellm/openrouter-api-key        litellm/factory-api-key
    litellm/positron_anthropic-api-key
    litellm/positron_gemini-api-key
    litellm/positron_openai-api-key
    litellm/positron-api-key
    openclaw/litellm-virtual-key

  Renaming the two still-live entries to non-LiteLLM names is also a manual
  `sops` edit; if you do it, update the `key =` pointers in
  hera-llm-proxy.nix, rspamd.nix, vane.nix, hermes-self-heal.nix and
  openclaw-self-heal.nix in the same change.
EOF

note "Done"
(( COMMIT )) || echo "  (dry run — re-run with --commit to apply)"
