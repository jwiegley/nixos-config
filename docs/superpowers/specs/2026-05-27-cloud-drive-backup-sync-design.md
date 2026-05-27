# Cloud Drive Backup — Nightly One-Way Mirror to ZFS

**Status:** Design (approved 2026-05-27)
**Host:** vulcan
**Author:** John Wiegley (with Claude Code)

## 1. Goal

Maintain a complete, regularly-refreshed, **one-way** local mirror of the
cloud-drive accounts John actively uses, so the data survives loss of (or
lockout from) any cloud account. Each account mirrors into its own ZFS dataset
under `tank/Backups`. History is provided by the existing **sanoid** snapshot
system rather than by accumulating stale files, so the live copy stays a clean
reflection of current cloud state while deletions/edits remain recoverable from
snapshots.

## 2. Scope

### In scope — 4 rclone remotes

| rclone remote | account | type | auth source |
|---|---|---|---|
| `assembly` | carmichaellsa@gmail.com | Google Drive | migrate token from `hera` |
| `bia` | john@bia.bahai.org | Google Drive (Workspace) | migrate token from `hera` |
| `gdrive` | jwiegley@gmail.com | Google Drive | migrate token from `hera` |
| `onedrive` | jwiegley@gmail.com (Microsoft personal) | OneDrive | **fresh** one-time browser OAuth |

Per chosen scope, each Google account mirrors **My Drive + Shared-with-me +
Shared Drives**.

### Out of scope

- **iCloud** — already synced to `tank/iCloud` (a Samba share fed from John's
  Mac). Untouched.
- **Off-site (Backblaze B2) copy** of the mirrors — explicitly excluded to avoid
  re-uploading TBs of cloud data and incurring B2 cost (see §5.6).
- At-rest encryption of the mirror — lands on trusted local ZFS; `rclone crypt`
  would add friction for no security gain here.

## 3. Locked decisions (with rationale)

1. **rclone-direct, not Mac-relay.** vulcan pulls straight from the Google /
   Microsoft APIs. Both have first-class APIs (unlike iCloud, which is why
   *that* one goes through the Mac), so direct pull is fully unattended, runs
   regardless of whether any Mac is awake, and captures complete contents rather
   than macOS "dataless" placeholder stubs.
2. **`rclone sync` (true mirror) + sanoid snapshots for history**, not
   `rclone copy` (accumulates cruft/renamed duplicates) and not
   `--backup-dir` (redundant with ZFS snapshots). Mirror keeps the live copy
   clean; snapshots make deletions recoverable.
3. **Nightly at 01:00**, ahead of the existing 02:00 restic / PostgreSQL backup
   cluster, to avoid resource stacking.
4. **Server-side only** — no Samba exposure for these datasets (unlike
   `tank/iCloud`).
5. **Tokens migrate; OneDrive re-auths once.** Google OAuth refresh tokens are
   not machine-bound, so copying the remote stanzas from `hera` carries the
   grant; both machines may use the same token concurrently. OneDrive has no
   token on `hera`, so it needs one interactive browser authorization.

## 4. Architecture / data flow

```
                          (nightly 01:00 timer)
                                   │
                                   ▼
        rclone-cloud-backup.service  (single nightly oneshot)
                 │  iterates the 4 remotes sequentially (continue-on-error)
   ┌───────────────────────────────────────────────────────────────────────┐
   │  for each remote:                                                       │
   │    RCLONE_CONFIG=/run/secrets/rclone-cloudbackup-config  (SOPS, 0400)   │
   │    rclone sync  <remote>:        → dataset/MyDrive                       │
   │    rclone sync  <remote>: (SWM)  → dataset/SharedWithMe   (Google only)  │
   │    for each shared drive:        → dataset/SharedDrives/<name> (Google)  │
   │    write rclone_last_success_timestamp_seconds  (node-exporter textfile) │
   │    OnFailure → alert                                                     │
   └───────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
   tank/Backups/GoogleDrive/{assembly,bia,jwiegley}, tank/Backups/OneDrive
                                   │
                          (sanoid hourly/daily/...)
                                   ▼
                         ZFS snapshots = point-in-time history
```

## 5. Components

### 5.1 ZFS datasets

Created idempotently by a setup unit (`zfs list … || zfs create …`; nixpkgs has
no declarative arbitrary-dataset option), owned `rclone-backup:rclone-backup`,
mode `0700`:

```
tank/Backups/GoogleDrive            (container dataset)
tank/Backups/GoogleDrive/assembly
tank/Backups/GoogleDrive/bia
tank/Backups/GoogleDrive/jwiegley   (fed by hera remote "gdrive")
tank/Backups/OneDrive
```

Within each Google account dataset, plain directories (not datasets):
`MyDrive/`, `SharedWithMe/`, `SharedDrives/<drive-name>/`.

> **Naming note:** an unrelated local-backup dataset `tank/Backups/Assembly`
> already exists — distinct from the Google mirror
> `tank/Backups/GoogleDrive/assembly` (different paths, identical leaf name); no
> conflict, just flagged for awareness.

> **Data-loss guard (per CLAUDE.md):** persistent storage uses ZFS datasets, NOT
> `tmpfiles.rules` `D`/`d` directives. No tmpfiles entry is created for these
> paths.

### 5.2 Service user

`users.users.rclone-backup` — `isSystemUser`, dedicated group, home
`/var/lib/rclone-backup` (holds rclone cache/state). Can read only its own SOPS
secret; cannot read other services' secrets.

### 5.3 systemd units

- `rclone-cloud-backup.timer` — `OnCalendar=*-*-* 01:00:00`, `Persistent=true`.
- A **single** `oneshot` `rclone-cloud-backup.service` iterates the four remotes
  in sequence (continue-on-error per remote, so one failure doesn't block the
  rest), running the rclone passes (§5.5) and writing a per-remote freshness
  metric (§5.7) on each success. `TimeoutStartSec=infinity` (initial sync can run
  for hours). `OnFailure=` is wired to the repo's existing
  `backup-alert@%n.service` template (the same one restic jobs use).
- A `rclone-cloud-backup-setup.service` (oneshot, root) idempotently creates the
  datasets and sets ownership before the sync runs.
- Hardening: `NoNewPrivileges=true`, `ProtectSystem=strict`,
  `ReadWritePaths=/tank/Backups/… /var/lib/rclone-backup
  <node-exporter textfile dir>`, `ProtectHome=true`, `PrivateTmp=true`,
  `ProtectKernelTunables/Modules=true`, `RestrictAddressFamilies=AF_INET
  AF_INET6 AF_UNIX`.

### 5.4 Secrets (SOPS)

- The migrated 3 Google remotes **plus** the OneDrive token live in one
  `rclone.conf`, stored SOPS-encrypted as `secrets/rclone-cloudbackup.conf`.
- A `.sops.yaml` `creation_rule` is added for
  `secrets/rclone-cloudbackup\.conf$` (binary store; current sole rule only
  matches `.*\.yaml$`).
- Declared via `sops.secrets."rclone-cloudbackup-config" = { format = "binary";
  sopsFile = ../../secrets/rclone-cloudbackup.conf; owner = "rclone-backup";
  mode = "0400"; }`, deployed to `/run/secrets/rclone-cloudbackup-config`.
- Service sets `RCLONE_CONFIG=/run/secrets/rclone-cloudbackup-config`.
- **Note:** a separate `rclone-config` SOPS secret already exists for the gitea
  actions runner (`/run/secrets/rclone-config`, root:keys, 0440). This is a
  distinct secret (`rclone-cloudbackup-config`) — no collision. It is also the
  repo's first `format = "binary"` separate-file secret (all current secrets
  live in `secrets.yaml`); binary format is standard sops-nix.

### 5.5 Per-Google-account multi-pass sync

To capture My Drive **and** Shared-with-me **and** Shared Drives without editing
the migrated token blob, use rclone flags rather than extra remotes:

```bash
# My Drive
rclone sync <remote>: <dataset>/MyDrive       <common-flags>
# Shared-with-me (flag flips the remote's view; separate destination)
rclone sync <remote>: <dataset>/SharedWithMe  --drive-shared-with-me <common-flags>
# Shared Drives (enumerate, then one pass each)
for id,name in $(rclone backend drives <remote>:):
    rclone sync <remote>: <dataset>/SharedDrives/<name> --drive-team-drive <id> <common-flags>
```

`rclone backend drives <remote>:` returns empty for personal accounts (assembly,
jwiegley likely) — the loop is a no-op there; `bia` (Workspace) is where Shared
Drives are expected. OneDrive personal runs a single `rclone sync onedrive: …`
pass (no Shared-Drive concept; shared-with-me optional/minor).

> The pseudocode above is illustrative. Implementation must nail down JSON
> parsing of `rclone backend drives` output and **sanitize `<drive-name>`**
> (spaces/slashes in a Shared Drive's name must not create unintended path
> components).

`<common-flags>`: `--fast-list --track-renames
--drive-export-formats docx,xlsx,pptx,svg,csv --drive-acknowledge-abuse
--transfers 8 --checkers 16 --max-delete <N> --max-delete-size <size>
--log-level INFO --stats-one-line`.

- **`--drive-export-formats`**: native Google Docs/Sheets/Slides have no binary;
  this exports them to real files instead of 0-byte stubs.
- **`--max-delete` / `--max-delete-size`**: hard guard — if an auth/listing
  glitch makes the remote look empty, the mirror is **not** wiped (sync aborts).
- **`--track-renames`**: avoid re-downloading moved files.

### 5.6 sanoid (history)

**No sanoid change required.** `services.sanoid` already snapshots `tank` with
`recursive = true; process_children_only = true` using the `archival` template
(daily 30 / weekly 8 / monthly 12 / yearly 5). Datasets created under
`tank/Backups/…` inherit that policy automatically. We deliberately rely on the
inherited `archival` retention rather than adding a divergent template — extra
history is essentially free (ZFS copy-on-write) and keeps these datasets
consistent with the rest of `tank`. (If a cloud mirror later proves too churny
to justify `archival` retention, add an explicit lighter override at that
point — deferred, not now.)

### 5.7 B2 exclusion

Add `"GoogleDrive"` and `"OneDrive"` to `backupExcludes` in
`modules/storage/backups.nix` (the `Backups` restic job backs up `/tank/Backups`
→ B2 bucket `Backups-Misc`; these strings are relative-path excludes, matching
existing entries like `PostgreSQL`, `Machines`). Keeps the mirrors local-only.

### 5.8 Monitoring / alerting

- Each service writes `rclone_last_success_timestamp_seconds{remote="…"}` to the
  node-exporter textfile-collector directory
  (`/var/lib/prometheus-node-exporter-textfiles`; confirm during implementation).
- A **Prometheus alerting rule** — a rules file auto-discovered from
  `modules/monitoring/alerts/`, *not* Alertmanager config — fires when
  `time() - rclone_last_success_timestamp_seconds > 36h` for any remote,
  **plus an `absent(...)` clause** so a remote that has *never* succeeded also
  alerts. Mirrors `alerts/local-backup.yaml`.
- `OnFailure=` on the sync service is wired to the existing
  `backup-alert@%n.service` template (same as restic jobs) for immediate
  failure notification.
- No new listening port → no `docs/ports.txt` change (metrics are textfile, not
  a new exporter daemon).

## 6. Secret handling & manual gates

Two steps are performed **by John**, never by Claude (rclone tokens must never
enter the conversation or logs; the output-redactor does not even recognize
Google `1//…` refresh tokens):

**Gate 1 — migrate Google tokens from `hera`:**
```bash
(umask 077; ssh hera 'rclone config show' > /tmp/rcb.conf)   # all 3 remotes; machine-to-machine
cp /tmp/rcb.conf /etc/nixos/secrets/rclone-cloudbackup.conf
sops --encrypt --in-place /etc/nixos/secrets/rclone-cloudbackup.conf  # now ciphertext, safe to commit
shred -u /tmp/rcb.conf
```
(Claude first adds the `.sops.yaml` rule and the `secrets/` path so the
`sops --encrypt` matches a creation rule.)

**Gate 2 — add OneDrive:** run `rclone authorize "onedrive"` on any machine with
a browser; add the resulting `[onedrive]` stanza into the SOPS-encrypted config
(via `sops /etc/nixos/secrets/rclone-cloudbackup.conf`) alongside the Google
remotes.

## 7. Files to change

| File | Change |
|---|---|
| `modules/services/rclone-cloud-backup.nix` | **new** — user, secret decl, dataset setup unit, sync service (loops over remotes) + timer, hardening, metric, OnFailure |
| `.sops.yaml` | add `creation_rule` for `secrets/rclone-cloudbackup\.conf$` |
| `secrets/rclone-cloudbackup.conf` | **new** — SOPS-encrypted rclone.conf (created via §6) |
| `modules/storage/zfs.nix` | *(no change — new datasets inherit `tank`'s recursive `archival` sanoid policy)* |
| `modules/storage/backups.nix` | add `"GoogleDrive"`, `"OneDrive"` to `backupExcludes` |
| `modules/monitoring/alerts/rclone-cloud-backup.yaml` | **new** — Prometheus alerting rule for sync staleness |
| `configuration.nix` / module import | import the new module |

## 8. Verification / testing

1. `nix flake check` and `nixos-rebuild build --flake '.#vulcan'` succeed.
2. Setup unit creates the 5 datasets with correct ownership/mode (`zfs list`,
   `ls -lad`).
3. `rclone --config /run/secrets/rclone-cloudbackup-config listremotes` shows
   `assembly: bia: gdrive: onedrive:` (run as `rclone-backup`; names only — no
   secret output).
4. Dry-run each remote: `rclone sync --dry-run …` — sane file counts, no errors.
5. First real sync run manually (large/long), verify data lands under the right
   dataset/subdirs and Google Docs exported (no 0-byte stubs).
6. Freshness metric present and scraped; force a failure (bad flag) → confirm
   Alertmanager fires; restore.
7. Confirm restic skips the mirrors (build-time: excludes present;
   `restic … backup --dry-run` or snapshot listing shows them absent).
8. `--max-delete` guard: point a test pass at an empty/wrong remote in dry-run,
   confirm it would abort rather than delete.

## 9. Rollback

- Disable/stop `rclone-cloud-backup.timer` and the `rclone-cloud-backup`
  service; remove the module import. Data and snapshots remain.
- To fully remove: `zfs destroy -r tank/Backups/GoogleDrive` and
  `tank/Backups/OneDrive` (destroys snapshots too — deliberate), remove sanoid
  entries, `backupExcludes` entries, `.sops.yaml` rule, and the encrypted
  secret. No reboot required.

## 10. Operational notes / risks

- **Initial sync volume/time** is unbounded a priori (especially
  Shared-with-me, which can include large folders others shared, and `bia`
  Workspace Shared Drives). Run the first sync manually, watch
  `tank` free space (currently 11.2 TB free). Oversized/unwanted shares can be
  blacklisted per-account later.
- **API quota:** Google Drive API has per-project/day limits; serialized nightly
  syncs with `--fast-list`/`--track-renames` keep requests modest. Using
  rclone's built-in OAuth client (shared) is acceptable; a dedicated Google
  Cloud OAuth client is a future hardening if rate-limited.
- **Token sharing with `hera`:** the same Google refresh token used from both
  hosts is fine; no need to deauthorize `hera`.
- **`--drive-export-formats`** loses fidelity for unusual Google file types
  (e.g., Forms, Sites have no export); acceptable for a file backup.

## 11. Future / explicitly deferred

- Dedicated per-host Google OAuth client (only if quota becomes an issue).
- Off-site (B2) copy of the mirrors (deliberately excluded now).
- Adding OneDrive "shared with me" if it proves relevant.
- Samba read-only browse access (declined now; trivial to add later).
