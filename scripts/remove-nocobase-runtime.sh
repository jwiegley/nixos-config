#!/usr/bin/env bash
#
# Runtime cleanup for the NocoBase removal of 2026-08-31.
#
# The Nix side is already done (commit removing modules/containers/nocobase-quadlet.nix
# and modules/users/home-manager/nocobase.nix). Removing a service from the Nix config
# does NOT remove its runtime traces, so this script clears the rest.
#
# WHAT THIS DELIBERATELY DOES NOT DO
# ----------------------------------
#   * SOPS secrets. `nocobase-db-password` and `nocobase-secrets` stay in
#     secrets.yaml until the operator removes them with `sops
#     /etc/nixos/secrets/secrets.yaml`. sops-nix ignores keys that nothing
#     declares, so leaving them is harmless; deleting them is the operator's call
#     and cannot be done safely from a script.
#   * Historical backups. /tank/Backups/PostgreSQL/db/nocobase is left in place --
#     it is the only remaining copy of the data once the live database is dropped.
#     It simply stops being updated. Remove it by hand if and when you want to.
#
# USAGE
# -----
#   sudo ./remove-nocobase-runtime.sh            # DRY RUN -- prints what it would do
#   sudo ./remove-nocobase-runtime.sh --apply    # actually do it
#
# Idempotent: every step checks for its target first, so a partial run can be
# re-run safely, and a second full run is a no-op.
#
# RUN THIS *AFTER* A SUCCESSFUL `/etc/nixos/build switch` with the NocoBase
# declarations removed. The precondition check below enforces that -- if the
# system still declares the user, deleting it here would just have the next
# switch recreate it.

set -euo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

NB_USER="nocobase"
NB_UID="945"
DATA_DIR="/var/lib/nocobase"
CONTAINER_HOME="/var/lib/containers/nocobase"
SECRETS_RUNDIR="/run/secrets-nocobase"
CERT_DIR="/var/lib/nginx-certs"
# OUTSIDE /tank/Backups/PostgreSQL on purpose. That path is the destination of an
# `rsync -a --delete` mirror published nightly by postgresql-backup.service. A
# root-owned directory there has no counterpart in the staging tree, so --delete
# tries to unlink it as the postgres user, fails with EACCES, and takes the whole
# backup down rc23 -- observed 2026-09-01 02:11, the first nightly run after this
# script was applied. A final dump must not live inside a mirror that is
# continuously pruned to match a source it will never appear in.
DUMP_DIR="/tank/Backups/removed-services"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n=== %s\n' "$*"; }

run() {
  if [[ $APPLY -eq 1 ]]; then
    printf '  RUN  %s\n' "$*"
    "$@"
  else
    printf '  SKIP %s\n' "$*"
  fi
}

# Same as run(), but for things that must go through a shell (pipes, redirects).
run_sh() {
  if [[ $APPLY -eq 1 ]]; then
    printf '  RUN  sh -c %q\n' "$1"
    bash -c "$1"
  else
    printf '  SKIP sh -c %q\n' "$1"
  fi
}

[[ $EUID -eq 0 ]] || { red "must run as root"; exit 1; }

if [[ $APPLY -eq 0 ]]; then
  ylw "DRY RUN. Nothing will be changed. Re-run with --apply to execute."
fi

# ---------------------------------------------------------------------------
step "Preconditions"
# ---------------------------------------------------------------------------
# The Nix config must no longer declare NocoBase, or this cleanup is pointless:
# the next switch would recreate the user, the tmpfiles dir and the container.
if grep -rqE '^\s*services\.nocobase\.enable\s*=\s*true' /etc/nixos/hosts /etc/nixos/modules 2>/dev/null; then
  red "/etc/nixos still enables services.nocobase. Deploy the removal first:"
  red "    cd /etc/nixos && ./build switch"
  exit 1
fi
grn "  Nix config no longer declares NocoBase"

# There is NO reliable system-scope test for "the switch has been applied".
# NocoBase ran as a ROOTLESS quadlet, so its unit lives under the nocobase user's
# own systemd --user tree, not in /etc/systemd/system -- and with
# mutableUsers = true the account persists on disk whether or not Nix still
# declares it. So this cannot be auto-verified; it is stated as a requirement
# instead of faked as a check.
ylw "  REQUIREMENT: run this only AFTER a successful '/etc/nixos/build switch'"
ylw "  with the NocoBase declarations removed. Otherwise the next switch simply"
ylw "  recreates what this deletes."
if [[ -d /run/user/$NB_UID ]]; then
  ylw "  (note: /run/user/$NB_UID still exists, so the user manager is still up --"
  ylw "   expected if you have not switched yet, and handled by step 1 either way)"
fi

# ---------------------------------------------------------------------------
step "1. Stop the rootless container and its user manager"
# ---------------------------------------------------------------------------
# Do the podman work FIRST: it needs the user's XDG_RUNTIME_DIR, which disappears
# once linger is revoked and the user is deleted.
if id -u "$NB_USER" >/dev/null 2>&1; then
  XRD="/run/user/$NB_UID"
  if [[ -d "$XRD" ]]; then
    run_sh "sudo -u $NB_USER XDG_RUNTIME_DIR=$XRD systemctl --user stop $NB_USER.service || true"
    run_sh "sudo -u $NB_USER XDG_RUNTIME_DIR=$XRD systemctl --user disable $NB_USER.service || true"

    step "2. Remove containers, images and volumes owned by $NB_USER"
    # `podman system reset -f` removes containers, pods, images, volumes and
    # networks for this user in one go. That is exactly the intent here, and it
    # is scoped to the rootless store under $CONTAINER_HOME -- it cannot touch
    # another user's containers or the root store.
    run_sh "sudo -u $NB_USER XDG_RUNTIME_DIR=$XRD podman system reset -f || true"
  else
    ylw "  $XRD absent (user manager not running); skipping podman teardown."
    ylw "  Removing $CONTAINER_HOME in step 6 clears the rootless store anyway."
  fi
else
  grn "  user $NB_USER already gone; nothing to stop"
fi

# ---------------------------------------------------------------------------
step "3. Final PostgreSQL dump before dropping the database"
# ---------------------------------------------------------------------------
# Taken BEFORE the drop on purpose. /tank/Backups/PostgreSQL/db/nocobase is a
# mirror that stops updating rather than a point-in-time archive, so this is the
# clean final snapshot.
if sudo -u postgres psql -Atqc "SELECT 1 FROM pg_database WHERE datname='nocobase'" 2>/dev/null | grep -q 1; then
  run mkdir -p "$DUMP_DIR"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  run_sh "sudo -u postgres pg_dump -Fc nocobase > '$DUMP_DIR/nocobase-final-$STAMP.dump'"
  run_sh "chmod 0600 '$DUMP_DIR/nocobase-final-$STAMP.dump' 2>/dev/null || true"
  grn "  final dump -> $DUMP_DIR/nocobase-final-$STAMP.dump"
else
  grn "  database 'nocobase' does not exist; no dump needed"
fi

# ---------------------------------------------------------------------------
step "4. Drop the database and role"
# ---------------------------------------------------------------------------
if sudo -u postgres psql -Atqc "SELECT 1 FROM pg_database WHERE datname='nocobase'" 2>/dev/null | grep -q 1; then
  # Terminate stragglers first; DROP DATABASE fails while any backend is attached.
  run_sh "sudo -u postgres psql -Atqc \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='nocobase' AND pid <> pg_backend_pid()\" >/dev/null || true"
  run_sh "sudo -u postgres psql -Atqc 'DROP DATABASE IF EXISTS nocobase'"
else
  grn "  database already absent"
fi

if sudo -u postgres psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='nocobase'" 2>/dev/null | grep -q 1; then
  # The role owned the database and the postgres_fdw USAGE grant. With the
  # database gone, REASSIGN/DROP OWNED has nothing left to move, but run DROP
  # OWNED anyway so any grant in another database cannot block the DROP ROLE.
  run_sh "sudo -u postgres psql -Atqc 'DROP OWNED BY nocobase CASCADE' 2>/dev/null || true"
  run_sh "sudo -u postgres psql -Atqc 'DROP ROLE IF EXISTS nocobase'"
else
  grn "  role already absent"
fi

# ---------------------------------------------------------------------------
step "5. Remove the nginx certificate"
# ---------------------------------------------------------------------------
# nocobase.vulcan.lan is already out of certs/renew-nginx-certs.sh, so nothing
# reissues it. Leaving the files behind keeps feeding the certificate exporter a
# name for a vhost that no longer exists -- the "stale-name accumulation" already
# tracked in docs/MONITORING_COVERAGE_PLAN.md.
for ext in crt key; do
  f="$CERT_DIR/nocobase.vulcan.lan.$ext"
  if [[ -e "$f" ]]; then run rm -f "$f"; else grn "  $f already absent"; fi
done

# ---------------------------------------------------------------------------
step "6. Remove data directories"
# ---------------------------------------------------------------------------
# $CONTAINER_HOME is the rootless podman store (~2.0G at removal time) and is the
# user's home. $DATA_DIR is the app's own state (~668K).
for d in "$DATA_DIR" "$CONTAINER_HOME" "$SECRETS_RUNDIR"; do
  if [[ -e "$d" ]]; then
    sz="$(du -sh "$d" 2>/dev/null | cut -f1 || echo '?')"
    printf '  %s exists (%s)\n' "$d" "$sz"
    run rm -rf "$d"
  else
    grn "  $d already absent"
  fi
done

# ---------------------------------------------------------------------------
step "7. Revoke systemd linger"
# ---------------------------------------------------------------------------
# mutableUsers = true means removing the Nix user declaration does NOT revoke
# linger. Left behind, systemd keeps a user manager alive for a user that no
# longer exists.
if [[ -e "/var/lib/systemd/linger/$NB_USER" ]]; then
  run loginctl disable-linger "$NB_USER"
  run rm -f "/var/lib/systemd/linger/$NB_USER"
else
  grn "  linger already revoked"
fi

# ---------------------------------------------------------------------------
step "8. Remove the user and group"
# ---------------------------------------------------------------------------
# Last, because everything above needed the account to exist.
if id -u "$NB_USER" >/dev/null 2>&1; then
  run_sh "pkill -u $NB_USER || true"
  run userdel "$NB_USER"
else
  grn "  user already removed"
fi
if getent group "$NB_USER" >/dev/null 2>&1; then
  run groupdel "$NB_USER"
else
  grn "  group already removed"
fi

# ---------------------------------------------------------------------------
step "9. Verification"
# ---------------------------------------------------------------------------
if [[ $APPLY -eq 1 ]]; then
  fail=0
  # Written as explicit if/else rather than `A && B || C`: in that form, if the
  # B group ever returned nonzero, C would run too and a FAILED check would also
  # print "gone". Shellcheck SC2015.
  check_absent() {  # check_absent <description> <test-command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
      red "  $desc still present"; fail=1
    else
      grn "  $desc gone"
    fi
  }
  pg_has() { sudo -u postgres psql -Atqc "$1" 2>/dev/null | grep -q 1; }

  check_absent "user"  id -u "$NB_USER"
  check_absent "group" getent group "$NB_USER"
  for d in "$DATA_DIR" "$CONTAINER_HOME"; do
    check_absent "$d" test -e "$d"
  done
  check_absent "database" pg_has "SELECT 1 FROM pg_database WHERE datname='nocobase'"
  check_absent "role"     pg_has "SELECT 1 FROM pg_roles WHERE rolname='nocobase'"
  check_absent "certificate" bash -c "ls $CERT_DIR/nocobase.vulcan.lan.* >/dev/null 2>&1"

  # Metric NAMES persist in Prometheus's __name__ index for the full retention
  # window and are NOT evidence of a live series -- test with count(), which is 0
  # once the container is gone. See the note in
  # memory: project_removed_service_residue_surfaces.
  if command -v curl >/dev/null 2>&1; then
    n="$(curl -s --max-time 10 'http://127.0.0.1:9090/api/v1/query?query=count(container_running%7Bname%3D%22nocobase%22%7D)' 2>/dev/null | grep -o '"value":\[[^]]*\]' | grep -oE '"[0-9]+"$' | tr -d '"' || true)"
    if [[ -z "${n:-}" ]]; then grn "  container_running{nocobase}: 0 series"; else ylw "  container_running{nocobase}: $n series (may take one scrape to clear)"; fi
  fi

  echo
  if [[ $fail -eq 0 ]]; then
    grn "NocoBase runtime removal complete."
  else
    red "Some checks failed -- see above."
    exit 1
  fi

  echo
  ylw "STILL YOURS TO DO:"
  ylw "  1. Remove the SOPS keys:  sops /etc/nixos/secrets/secrets.yaml"
  ylw "     -> delete 'nocobase-db-password' and 'nocobase-secrets'"
  ylw "  2. Optionally delete the stale backup mirror, which no longer updates:"
  ylw "     /tank/Backups/PostgreSQL/db/nocobase"
  ylw "     (the final dump from step 3 is under $DUMP_DIR)"
else
  echo
  ylw "Dry run complete. Re-run with --apply to execute."
fi
