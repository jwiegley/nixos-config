# Cloud Drive Backup — Implementation Plan

> **Archival — 2026-05-27.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/services/rclone-cloud-backup.nix`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nightly one-way `rclone` mirror of three Google Drive accounts plus one OneDrive into per-account ZFS datasets under `tank/Backups`, with sanoid snapshots for history and Prometheus freshness alerting.

**Architecture:** A single nightly systemd timer runs one oneshot service that, per remote, runs `rclone sync` (true mirror) directly from the provider API into a ZFS dataset, then writes a success-timestamp textfile metric. OAuth tokens live in one SOPS-encrypted `rclone.conf`. The three Google tokens are migrated from host `hera`; OneDrive is authorized once interactively. Snapshots come for free from `tank`'s existing recursive `archival` sanoid policy.

**Tech Stack:** NixOS modules, systemd (timer + oneshot), rclone, ZFS, sops-nix (binary secret), Prometheus node-exporter textfile collector, sanoid.

**Spec:** `docs/superpowers/specs/2026-05-27-cloud-drive-backup-sync-design.md`

---

## Prerequisites & ordering (READ FIRST)

- **No worktree.** This is the live system config at `/etc/nixos`; work directly there. There are unrelated uncommitted edits (`modules/services/home-assistant.nix`, `modules/services/zimit.nix`) — do **not** stage or commit those; only stage files this plan names.
- **Hard ordering:** the NixOS module (Task 4) references `sops.secrets` whose `sopsFile = ../../secrets/rclone-cloudbackup.conf`. That file must **exist on disk** for `nixos-rebuild build` to evaluate. Therefore **Tasks 2 and 3 (John's manual secret gates) MUST complete before Task 4 builds.** Task 1 must precede Task 2 (the `.sops.yaml` rule is needed for `sops --encrypt` to match).
- **🔒 SECRET RULE — the implementing agent must NEVER run the commands in Tasks 2 & 3.** They emit/handle OAuth refresh tokens. John runs them in his own shell. The agent does not `cat`, `rclone config show`, `sops -d`, or otherwise surface token material. (See CLAUDE.md PRIMARY LENS.)
- **No reboots.** `nixos-rebuild switch` (Task 8) is a system change John runs/approves; never reboot.
- Commit messages follow the repo's Conventional-Commits style and end with the `Co-Authored-By` trailer.

## File structure

| File | Responsibility | Action |
|---|---|---|
| `.sops.yaml` | SOPS creation rules | modify (add rule for the conf) |
| `secrets/rclone-cloudbackup.conf` | encrypted rclone.conf (4 remotes) | **create** (by John, Tasks 2–3) |
| `modules/services/rclone-cloud-backup.nix` | user, secret decl, dataset-setup unit, sync service, timer, metric | **create** |
| `hosts/vulcan/default.nix` | host module imports | modify (import the new module) |
| `modules/storage/backups.nix` | restic→B2 source/excludes | modify (`backupExcludes`) |
| `modules/monitoring/alerts/rclone-cloud-backup.yaml` | Prometheus alerting rule (auto-discovered) | **create** |

No `docs/ports.txt` change (no listening port). No `modules/storage/zfs.nix` change (sanoid inherits).

---

## Task 1: Add the SOPS creation rule for the rclone config

**Files:**
- Modify: `.sops.yaml`

- [ ] **Step 1: Add a more-specific rule above the existing `.yaml` rule**

Replace the contents of `.sops.yaml` with (the `pgp`/`age` recipients are the existing public ones — copy them verbatim from the current file):

```yaml
creation_rules:
    - path_regex: secrets/rclone-cloudbackup\.conf$
      pgp: "1476CCC0D9C897534A1F00ED6060E33E7AEE9418"
      age: >-
        age1hepljzv8l2quqn2ekv40qdeecnknz2rjzhnet533j4d3m7ag03eqyjrp3s,
        age1ma25mryt6yfg6gz0rvxvl3ndwpdw2njkp4sh5hvzmfqwhwanrepqny5qgz
    - path_regex: .*\.yaml$
      pgp: "1476CCC0D9C897534A1F00ED6060E33E7AEE9418"
      age: >-
        age1hepljzv8l2quqn2ekv40qdeecnknz2rjzhnet533j4d3m7ag03eqyjrp3s,
        age1ma25mryt6yfg6gz0rvxvl3ndwpdw2njkp4sh5hvzmfqwhwanrepqny5qgz
```

(sops uses the **first** matching rule, so the specific `.conf` rule must come first.)

- [ ] **Step 2: Create the secrets directory** (if not present)

Run: `mkdir -p /etc/nixos/secrets`
Expected: no error (idempotent).

- [ ] **Step 3: Verify the rule parses**

Run: `cd /etc/nixos && sops --version && grep -A1 'rclone-cloudbackup' .sops.yaml`
Expected: sops prints a version; grep shows the new `path_regex` line.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos
git add .sops.yaml
git commit -m "feat(rclone-backup): add SOPS rule for cloud-drive rclone config

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: 🔒👤 JOHN — migrate the three Google tokens from `hera` (Gate 1)

**Agent: do not execute. Present these to John and wait.** Tokens must never enter the conversation/logs.

**Files:**
- Create: `secrets/rclone-cloudbackup.conf` (encrypted)

- [ ] **Step 1: Pull all remotes from `hera` into a private temp file (machine-to-machine)**

```bash
(umask 077; ssh hera 'rclone config show' > /tmp/rcb.conf)
```
`rclone config show` (no arg) dumps every remote; on `hera` that's exactly `assembly`, `bia`, `gdrive`.

- [ ] **Step 2: Encrypt into the repo and destroy the plaintext**

```bash
cp /tmp/rcb.conf /etc/nixos/secrets/rclone-cloudbackup.conf
cd /etc/nixos && sops --encrypt --in-place secrets/rclone-cloudbackup.conf
shred -u /tmp/rcb.conf
```
Expected: `secrets/rclone-cloudbackup.conf` is now SOPS ciphertext (starts with sops/age metadata; `head -1` shows an encrypted/structured line, not `[assembly]`).

- [ ] **Step 3: Sanity check it's encrypted (no token leak)**

Run: `cd /etc/nixos && file secrets/rclone-cloudbackup.conf && grep -c 'ENC\[' secrets/rclone-cloudbackup.conf || true`
Expected: contains `ENC[...]` markers; **does not** contain a plaintext `token =` line. (Do not print the whole file.)

> OneDrive is added in Task 3 before the first commit of this file — or commit now and amend in Task 3. Either is fine.

---

## Task 3: 🔒👤 JOHN — authorize and add OneDrive (Gate 2)

**Agent: do not execute.** OneDrive has no token on `hera`; it needs one interactive browser auth.

- [ ] **Step 1: Authorize OneDrive on any machine with a browser**

```bash
rclone authorize "onedrive"
```
Follow the browser flow for the Microsoft account logging in as `jwiegley@gmail.com` (OneDrive Personal). Copy the JSON token blob it prints.

- [ ] **Step 2: Add the `[onedrive]` stanza into the encrypted config**

```bash
cd /etc/nixos && sops secrets/rclone-cloudbackup.conf
```
In the editor add:
```ini
[onedrive]
type = onedrive
token = {<paste the JSON token from step 1>}
drive_type = personal
# drive_id is filled by `rclone config`; if absent, run an interactive
# `rclone config` pass for OneDrive instead and paste the full stanza.
```
Save & exit (sops re-encrypts on close).

- [ ] **Step 3: Commit the encrypted secret**

```bash
cd /etc/nixos
git add secrets/rclone-cloudbackup.conf
git commit -m "feat(rclone-backup): add encrypted rclone config (3x gdrive + onedrive)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

> ✋ **Checkpoint:** Tasks 4+ require `secrets/rclone-cloudbackup.conf` to exist. Do not proceed until John confirms Tasks 2–3 are done.

---

## Task 4: Create the NixOS module and import it

**Files:**
- Create: `modules/services/rclone-cloud-backup.nix`
- Modify: `hosts/vulcan/default.nix` (imports)

- [ ] **Step 1: Write the module**

> **Design note (intentional divergence from spec §5.3 wording):** this uses a
> **single** oneshot service that loops over the four remotes (continue-on-error
> per remote) rather than four per-remote units — simpler, same per-remote
> metrics, and one failure doesn't block the others. The spec has been updated to
> match.

Create `modules/services/rclone-cloud-backup.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  user = "rclone-backup";
  configPath = config.sops.secrets."rclone-cloudbackup-config".path;
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  commonFlags = lib.concatStringsSep " " [
    "--config=${configPath}"
    "--fast-list"
    "--track-renames"
    "--transfers=8"
    "--checkers=16"
    "--max-delete=2000"
    "--max-delete-size=50G"
    "--retries=3"
    "--low-level-retries=10"
    "--log-level=INFO"
    "--stats=5m"
    "--stats-one-line"
  ];

  driveFlags = lib.concatStringsSep " " [
    "--drive-export-formats=docx,xlsx,pptx,svg,csv"
    "--drive-acknowledge-abuse"
  ];
in
{
  ##### service user #####
  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = "/var/lib/rclone-backup";
    description = "rclone cloud-drive backup";
  };
  users.groups.${user} = { };

  ##### migrated + onedrive OAuth config (SOPS, binary) #####
  sops.secrets."rclone-cloudbackup-config" = {
    format = "binary";
    sopsFile = ../../secrets/rclone-cloudbackup.conf;
    owner = user;
    group = user;
    mode = "0400";
  };

  ##### idempotent ZFS dataset creation + ownership #####
  systemd.services.rclone-cloud-backup-setup = {
    description = "Create/own ZFS datasets for cloud-drive backups";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs.target" "zfs-mount.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.zfs pkgs.coreutils ];
    script = ''
      set -euo pipefail
      datasets="tank/Backups/GoogleDrive \
        tank/Backups/GoogleDrive/assembly \
        tank/Backups/GoogleDrive/bia \
        tank/Backups/GoogleDrive/jwiegley \
        tank/Backups/OneDrive"
      for ds in $datasets; do
        if ! zfs list -H -o name "$ds" >/dev/null 2>&1; then
          zfs create "$ds"
        fi
      done
      for mp in /tank/Backups/GoogleDrive \
                /tank/Backups/GoogleDrive/assembly \
                /tank/Backups/GoogleDrive/bia \
                /tank/Backups/GoogleDrive/jwiegley \
                /tank/Backups/OneDrive; do
        chown ${user}:${user} "$mp"
        chmod 0700 "$mp"
      done
    '';
  };

  ##### nightly sync service #####
  systemd.services.rclone-cloud-backup = {
    description = "Nightly one-way mirror of cloud drives to ZFS";
    after = [ "network-online.target" "rclone-cloud-backup-setup.service" ];
    wants = [ "network-online.target" ];
    requires = [ "rclone-cloud-backup-setup.service" ];
    path = [ pkgs.rclone pkgs.jq pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      TimeoutStartSec = "infinity";   # initial sync can run for hours
      Nice = 19;
      IOSchedulingClass = "idle";
      StateDirectory = "rclone-backup";
      Environment = [
        "HOME=/var/lib/rclone-backup"
        "RCLONE_CONFIG=${configPath}"
      ];
      # hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      ReadWritePaths = [
        "/tank/Backups/GoogleDrive"
        "/tank/Backups/OneDrive"
        "/var/lib/rclone-backup"
        textfileDir
      ];
    };
    onFailure = [ "backup-alert@%n.service" ];   # same template restic jobs use
    script = ''
      set -uo pipefail
      export HOME=/var/lib/rclone-backup
      overall=0

      metric() {  # $1 = remote label
        local f
        f=$(mktemp "${textfileDir}/rclone-$1.prom.XXXXXX") || return 0
        printf 'rclone_last_success_timestamp_seconds{remote="%s"} %s\n' \
          "$1" "$(date +%s)" > "$f"
        chmod 0644 "$f"
        mv -f "$f" "${textfileDir}/rclone-$1.prom"
      }

      sync_google() {  # $1 = remote  $2 = dest
        local remote="$1" dest="$2" drives
        rclone sync "$remote": "$dest/MyDrive" ${commonFlags} ${driveFlags} || return 1
        rclone sync "$remote": "$dest/SharedWithMe" ${commonFlags} ${driveFlags} \
          --drive-shared-with-me || return 1
        drives=$(rclone backend drives "$remote": 2>/dev/null || echo '[]')
        printf '%s' "$drives" | jq -r '.[]? | "\(.id)\t\(.name)"' \
          | while IFS=$'\t' read -r id name; do
              [ -n "$id" ] || continue
              safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._- ' '_')
              rclone sync "$remote": "$dest/SharedDrives/$safe" \
                ${commonFlags} ${driveFlags} --drive-team-drive "$id" || exit 1
            done || return 1
        return 0
      }

      sync_onedrive() {  # $1 = remote  $2 = dest
        rclone sync "$1": "$2" ${commonFlags} || return 1
        return 0
      }

      if sync_google assembly /tank/Backups/GoogleDrive/assembly; then metric assembly; else overall=1; fi
      if sync_google bia      /tank/Backups/GoogleDrive/bia;      then metric bia;      else overall=1; fi
      if sync_google gdrive   /tank/Backups/GoogleDrive/jwiegley; then metric gdrive;   else overall=1; fi
      if sync_onedrive onedrive /tank/Backups/OneDrive;           then metric onedrive; else overall=1; fi

      exit $overall
    '';
  };

  ##### nightly timer #####
  systemd.timers.rclone-cloud-backup = {
    description = "Nightly cloud-drive mirror";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 01:00:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
```

- [ ] **Step 2: Import the module**

Open `hosts/vulcan/default.nix`, find the `imports = [ … ]` list containing the other `../../modules/services/*.nix` entries, and add (matching the existing relative-path style):

```nix
    ../../modules/services/rclone-cloud-backup.nix
```

- [ ] **Step 3: Format**

Run: `cd /etc/nixos && nix fmt`
Expected: reformats the new file in place, no errors.

- [ ] **Step 4: Evaluate**

Run: `cd /etc/nixos && nix flake check`
Expected: exit 0 (warnings about pre-existing deprecations are fine; no errors referencing `rclone-cloud-backup`).

- [ ] **Step 5: Build (does NOT activate)**

Run: `cd /etc/nixos && sudo nixos-rebuild build --flake '.#vulcan'`
Expected: builds a closure with no errors. If it errors with "sopsFile … does not exist", Tasks 2–3 weren't completed — STOP.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos
git add modules/services/rclone-cloud-backup.nix hosts/vulcan/default.nix
git commit -m "feat(rclone-backup): nightly one-way cloud-drive mirror to ZFS

Adds rclone-backup user, SOPS binary config secret, idempotent dataset
setup, nightly oneshot sync (sync_google: MyDrive + SharedWithMe + Shared
Drives; onedrive), and a freshness textfile metric.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Exclude the mirrors from the Backblaze B2 restic job

**Files:**
- Modify: `modules/storage/backups.nix` (`backupExcludes`, ~line 119)

- [ ] **Step 1: Add the two excludes**

In the `backupExcludes` list, after `"TechnitiumDNS"`, add:

```nix
    "GoogleDrive" # cloud-drive mirror: local-only, never pushed to B2
    "OneDrive"    # cloud-drive mirror: local-only, never pushed to B2
```

- [ ] **Step 2: Build**

Run: `cd /etc/nixos && nix fmt && sudo nixos-rebuild build --flake '.#vulcan'`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos
git add modules/storage/backups.nix
git commit -m "feat(rclone-backup): exclude cloud-drive mirrors from B2 restic job

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Add the Prometheus freshness alert

**Files:**
- Create: `modules/monitoring/alerts/rclone-cloud-backup.yaml`

- [ ] **Step 1: Confirm the alerts schema**

Run: `sed -n '1,30p' /etc/nixos/modules/monitoring/alerts/local-backup.yaml`
Expected: confirms the `groups: → rules: → alert:` shape and how `absent(...)` is used. Match that shape below.

- [ ] **Step 2: Write the rule file**

Create `modules/monitoring/alerts/rclone-cloud-backup.yaml`:

```yaml
groups:
  - name: rclone-cloud-backup
    rules:
      - alert: RcloneCloudBackupStale
        expr: time() - rclone_last_success_timestamp_seconds > 36 * 3600
        for: 30m
        labels:
          severity: warning
          category: storage
          service: rclone-cloud-backup
        annotations:
          summary: "Cloud-drive mirror stale: {{ $labels.remote }}"
          description: "rclone remote {{ $labels.remote }} has not completed a successful sync in over 36 hours."
      - alert: RcloneCloudBackupNeverRan
        expr: absent(rclone_last_success_timestamp_seconds)
        for: 2h
        labels:
          severity: warning
          category: storage
          service: rclone-cloud-backup
        annotations:
          summary: "Cloud-drive mirror metric absent"
          description: "No rclone_last_success_timestamp_seconds present — cloud-drive backup has not reported success since deploy."
```

- [ ] **Step 3: Build (auto-discovery picks up the file)**

Run: `cd /etc/nixos && sudo nixos-rebuild build --flake '.#vulcan'`
Expected: exit 0. (`modules/monitoring/services/alerting.nix` auto-discovers `alerts/*.yaml`.)

- [ ] **Step 4: Validate the rule syntax** (if `promtool` is available)

Run: `nix shell nixpkgs#prometheus -c promtool check rules /etc/nixos/modules/monitoring/alerts/rclone-cloud-backup.yaml`
Expected: `SUCCESS: 2 rules found`. (If `promtool` unavailable, rely on the post-switch reload check in Task 8.)

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos
git add modules/monitoring/alerts/rclone-cloud-backup.yaml
git commit -m "feat(rclone-backup): alert when a cloud-drive mirror goes stale

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: 👤 Deploy

- [ ] **Step 1: John activates** (system change; never reboot)

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
```
Expected: activates without error.

- [ ] **Step 2: Verify the secret deployed**

Run: `stat -c '%n %U:%G %a' /run/secrets/rclone-cloudbackup-config`
Expected: `… rclone-backup:rclone-backup 400`. (Do **not** cat it.)

- [ ] **Step 3: Verify datasets were created**

Run: `systemctl status rclone-cloud-backup-setup.service --no-pager && zfs list -r -o name,used,mountpoint tank/Backups/GoogleDrive tank/Backups/OneDrive`
Expected: setup service `active (exited)`; five datasets listed with correct mountpoints owned appropriately.

---

## Task 8: Verify connectivity, alert loading, and B2 exclusion

- [ ] **Step 1: Remotes resolve (names only — no secrets printed)**

Run: `sudo -u rclone-backup RCLONE_CONFIG=/run/secrets/rclone-cloudbackup-config rclone listremotes`
Expected: `assembly:`, `bia:`, `gdrive:`, `onedrive:`.

- [ ] **Step 2: Connectivity probe per remote (top-level dir listing)**

Run (per remote):
```bash
sudo -u rclone-backup RCLONE_CONFIG=/run/secrets/rclone-cloudbackup-config HOME=/var/lib/rclone-backup rclone lsd assembly: | head
```
Repeat for `bia:`, `gdrive:`, `onedrive:`.
Expected: directory listings (proves auth works). Re-auth `onedrive` if it errors.

- [ ] **Step 3: Dry-run guard check**

Run: `sudo -u rclone-backup RCLONE_CONFIG=/run/secrets/rclone-cloudbackup-config HOME=/var/lib/rclone-backup rclone sync gdrive: /tank/Backups/GoogleDrive/jwiegley/MyDrive --drive-export-formats docx,xlsx,pptx,svg,csv --max-delete 2000 --dry-run | tail`
Expected: a plausible transfer plan, no "Too many deletes" abort on first run (dest empty).

- [ ] **Step 4: Alert rule is live**

Run: `curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[].name' | grep -i rclone` (adjust Prometheus port/host per `docs/ports.txt` if needed)
Expected: `RcloneCloudBackupStale` and `RcloneCloudBackupNeverRan` present.

- [ ] **Step 5: Confirm B2 job excludes the mirrors**

Run: `grep -A12 'backupExcludes = ' /etc/nixos/modules/storage/backups.nix | grep -E 'GoogleDrive|OneDrive'`
Expected: both present. (Build-time guarantee; restic will skip them.)

---

## Task 9: 👤 First real sync + metric verification

- [ ] **Step 1: Trigger the sync manually** (initial run may take a long time)

```bash
sudo systemctl start rclone-cloud-backup.service
journalctl -u rclone-cloud-backup.service -f
```
Watch for per-remote `--stats-one-line` progress; no auth/permission errors.

- [ ] **Step 2: Verify data landed with the expected structure**

Run: `find /tank/Backups/GoogleDrive -maxdepth 2 -type d | sort && du -sh /tank/Backups/GoogleDrive/* /tank/Backups/OneDrive`
Expected: `MyDrive/`, `SharedWithMe/`, and (for `bia`) `SharedDrives/<name>/`; non-trivial sizes.

- [ ] **Step 3: Confirm Google Docs exported as real files (no 0-byte stubs)**

Run: `find /tank/Backups/GoogleDrive -name '*.docx' -o -name '*.xlsx' | head` then `find /tank/Backups/GoogleDrive -type f -size 0 | head`
Expected: exported Office files exist; few/no unexpected 0-byte files.

- [ ] **Step 4: Verify freshness metrics were written**

Run: `ls -l /var/lib/prometheus-node-exporter-textfiles/rclone-*.prom && cat /var/lib/prometheus-node-exporter-textfiles/rclone-assembly.prom`
Expected: four `.prom` files; the metric line `rclone_last_success_timestamp_seconds{remote="assembly"} <epoch>`. (These are timestamps, not secrets.)

- [ ] **Step 5: Confirm the timer is scheduled**

Run: `systemctl list-timers rclone-cloud-backup.timer --no-pager`
Expected: next trigger ~01:00.

---

## Done / rollback

- **Done when:** all five datasets populate nightly, four metrics update, and the stale alert is wired.
- **Rollback:** stop+disable `rclone-cloud-backup.timer`, remove the import from `hosts/vulcan/default.nix`, `nixos-rebuild switch`. Data/snapshots remain. Full teardown: `zfs destroy -r tank/Backups/GoogleDrive tank/Backups/OneDrive`, revert `backupExcludes`, `.sops.yaml` rule, delete the secret and alert file. No reboot.
