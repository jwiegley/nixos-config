#!/usr/bin/env bash
# Safely retire Syncthing-owned payload metadata after the NixOS service has
# been removed. This script never deletes payloads, markers, daemon state,
# certificates, or secrets, and never changes ZFS acltype.
#
# Run only after a successful nixos-rebuild build of the removal branch:
#   sudo ./scripts/cleanup-syncthing-metadata.sh audit
#   sudo ./scripts/cleanup-syncthing-metadata.sh apply-ownership --yes
#   sudo ./scripts/cleanup-syncthing-metadata.sh apply-acls --yes
#
# Each mutating stage creates root-only ACL/stat rollback artifacts and named
# ZFS snapshots under /var/lib/syncthing-removal. Snapshots are reference-only:
# never roll back a live dataset with unrelated sibling writers.

set -euo pipefail
umask 077
export LC_ALL=C

readonly legacy_uid=237
readonly legacy_gid=237
readonly johnw_uid=1000
readonly johnw_gid=990
# GID 990 also includes nagios and prometheus. Keep John as payload owner but
# use root as the Public group so the migration cannot broaden daemon access.
readonly public_gid=0
readonly immich_gid=923
readonly public_root=/tank/Public
readonly public_johnw=/tank/Public/johnw
readonly video_parent=/tank/Video
readonly inbox_root=/tank/Video/Inbox
readonly state_root=/var/lib/syncthing-removal
readonly ss_bin=/run/current-system/sw/bin/ss

readonly -a public_admin_paths=(
  /tank/Public/.stignore
  /tank/Public/.stfolder
  /tank/Public/.stfolder/syncthing-folder-48ab5f.txt
  /tank/Public/.syncthing.tmp.961735510
)

usage() {
  printf '%s\n' \
    "Usage: $0 audit" \
    "       $0 apply-ownership --yes" \
    "       $0 apply-acls --yes" \
    "" \
    "audit is read-only. The apply modes create rollback artifacts and" \
    "ZFS snapshots before changing metadata. No mode deletes files."
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

count_exact_legacy() {
  find "$1" -xdev -uid "$legacy_uid" -gid "$legacy_gid" -printf . | wc -c | tr -d '[:space:]'
}

count_exact_owner() {
  find "$1" -xdev -uid "$2" -gid "$3" -printf . | wc -c | tr -d '[:space:]'
}

count_any_legacy() {
  {
    find "$public_root" -xdev \( -uid "$legacy_uid" -o -gid "$legacy_gid" \) -printf .
    find "$inbox_root" -xdev \( -uid "$legacy_uid" -o -gid "$legacy_gid" \) -printf .
  } | wc -c | tr -d '[:space:]'
}

assert_no_identity_mismatch() {
  local count
  count=$(
    {
      find "$public_root" -xdev \
        \( \( -uid "$legacy_uid" ! -gid "$legacy_gid" \) -o \
           \( ! -uid "$legacy_uid" -gid "$legacy_gid" \) \) -printf .
      find "$inbox_root" -xdev \
        \( \( -uid "$legacy_uid" ! -gid "$legacy_gid" \) -o \
           \( ! -uid "$legacy_uid" -gid "$legacy_gid" \) \) -printf .
    } | wc -c | tr -d '[:space:]'
  )
  [[ "$count" == 0 ]] || die "UID-only or GID-only legacy ownership appeared; refusing broad remediation"
}

assert_no_unsafe_types() {
  local count
  count=$(
    {
      find "$public_root" -xdev -uid "$legacy_uid" -gid "$legacy_gid" \
        ! -type f ! -type d -printf .
      find "$inbox_root" -xdev -uid "$legacy_uid" -gid "$legacy_gid" \
        ! -type f ! -type d -printf .
      find "$public_root" -xdev -uid "$legacy_uid" -gid "$legacy_gid" \
        -perm /6000 -printf .
      find "$inbox_root" -xdev -uid "$legacy_uid" -gid "$legacy_gid" \
        -perm /6000 -printf .
    } | wc -c | tr -d '[:space:]'
  )
  [[ "$count" == 0 ]] || die "legacy-owned symlink, special file, or set-ID object appeared"
}

assert_marker() {
  local path=$1
  local expected=$2
  [[ -e "$path" ]] || die "expected retained marker is absent: $path"
  [[ "$(stat -c '%F:%a:%u:%g' -- "$path")" == "$expected" ]] ||
    die "retained marker metadata drifted: $path"
}

assert_identity_and_host() {
  local service
  local group_id
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root with sudo"
  [[ "$(hostname -s)" == vulcan ]] || die "this script may run only on vulcan"

  [[ "$(id -u johnw)" == "$johnw_uid" ]] || die "johnw UID changed"
  [[ "$(id -g johnw)" == "$johnw_gid" ]] || die "johnw primary GID changed"
  [[ "$(getent group "$public_gid" | cut -d: -f3)" == "$public_gid" ]] ||
    die "root GID changed"
  [[ "$(getent group immich | cut -d: -f3)" == "$immich_gid" ]] ||
    die "immich GID changed"
  for service in nagios prometheus; do
    for group_id in $(id -G "$service"); do
      [[ "$group_id" != "$public_gid" ]] ||
        die "$service unexpectedly belongs to the Public destination group"
    done
  done
  [[ "$(stat -c '%u:%g' -- "$video_parent")" == "$johnw_uid:$immich_gid" ]] ||
    die "/tank/Video ownership no longer matches johnw:immich"

  if getent passwd "$legacy_uid" >/dev/null; then
    die "legacy UID $legacy_uid has been reassigned to a live principal"
  fi
  if getent group "$legacy_gid" >/dev/null; then
    die "legacy GID $legacy_gid has been reassigned to a live group"
  fi
}

assert_service_absent() {
  local listeners
  if systemctl is-active --quiet syncthing.service; then
    die "syncthing.service is active"
  fi
  if pgrep -x syncthing >/dev/null; then
    die "a Syncthing process is still running"
  fi
  listeners=$("$ss_bin" -H -lntu)
  if grep -Eq ':(8384|22000|21027)([[:space:]]|$)' <<<"$listeners"; then
    die "a retired Syncthing port has a live listener"
  fi
}

assert_acltype() {
  [[ "$(zfs get -H -o value acltype tank/Public)" == posix ]] ||
    die "tank/Public acltype is not posix"
  [[ "$(zfs get -H -o value acltype tank/Video)" == posix ]] ||
    die "tank/Video acltype is not posix"
}

preconditions() {
  local cmd
  for cmd in awk bash chmod chown cmp cut date find getent getfacl grep \
    hostname id install pgrep setfacl stat systemctl tr wc zfs; do
    need "$cmd"
  done
  [[ -x "$ss_bin" ]] || die "iproute2 ss is absent at $ss_bin"
  [[ -d "$public_root" && -d "$public_johnw" && -d "$inbox_root" ]] ||
    die "a former payload root is absent"
  assert_identity_and_host
  assert_service_absent
  assert_acltype
  assert_no_identity_mismatch
  assert_no_unsafe_types
}

assert_original_ownership_shape() {
  [[ "$(count_exact_legacy "$public_root")" == 1160 ]] ||
    die "Public legacy ownership count drifted from 1160"
  [[ "$(count_exact_legacy "$public_johnw")" == 1156 ]] ||
    die "Public/johnw legacy ownership count drifted from 1156"
  [[ "$(count_exact_legacy "$inbox_root")" == 23 ]] ||
    die "Video/Inbox legacy ownership count drifted from 23"

  assert_marker /tank/Public/.stignore 'regular file:670:237:237'
  assert_marker /tank/Public/.stfolder 'directory:775:237:237'
  assert_marker /tank/Public/.stfolder/syncthing-folder-48ab5f.txt \
    'regular file:674:237:237'
  assert_marker /tank/Public/.syncthing.tmp.961735510 \
    'regular file:670:237:237'
}

assert_payload_ownership_clean() {
  [[ "$(count_any_legacy)" == 0 ]] ||
    die "legacy UID or GID remains in a former payload root"
}

assert_ownership_targets() {
  [[ "$(count_exact_owner "$public_johnw" "$johnw_uid" "$public_gid")" == 1156 ]] ||
    die "Public/johnw did not converge to the exact johnw:root target"
  [[ "$(count_exact_owner "$inbox_root" "$johnw_uid" "$immich_gid")" == 23 ]] ||
    die "Video/Inbox did not converge to the exact johnw:immich target"

  [[ "$(stat -c '%F:%a:%u:%g' -- /tank/Public/.stignore)" == \
    'regular file:670:0:0' ]] || die "retained .stignore target drifted"
  [[ "$(stat -c '%F:%a:%u:%g' -- /tank/Public/.stfolder)" == \
    'directory:775:0:0' ]] || die "retained .stfolder target drifted"
  [[ "$(stat -c '%F:%a:%u:%g' -- /tank/Public/.stfolder/syncthing-folder-48ab5f.txt)" == \
    'regular file:674:0:0' ]] || die "retained folder marker target drifted"
  [[ "$(stat -c '%F:%a:%u:%g' -- /tank/Public/.syncthing.tmp.961735510)" == \
    'regular file:670:0:0' ]] || die "retained temp marker target drifted"
}

acl_counts() {
  {
    getfacl -R -p -n -- "$public_root"
    getfacl -R -p -n -- "$inbox_root"
    getfacl -p -n -- "$video_parent"
  } 2>/dev/null |
    awk -F: '
      $1 == "user" && $2 == "237" { access++ }
      $1 == "default" && $2 == "user" && $3 == "237" { defaults++ }
      END { printf "%d %d\n", access + 0, defaults + 0 }
    '
}

nonlegacy_acl_dump() {
  {
    getfacl -R -p -n -- "$public_root"
    getfacl -R -p -n -- "$inbox_root"
    getfacl -p -n -- "$video_parent"
  } 2>/dev/null |
    grep -Ev '^(user:237:|default:user:237:)'
}

checkpoint_dir=
snapshot_name=

make_checkpoint() {
  local stage=$1
  local stamp
  local dataset
  local root
  local path
  local acl
  local access_perm
  local default_perm
  local restore_count
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  checkpoint_dir="$state_root/$stamp-$stage"
  snapshot_name="pre-syncthing-$stage-$stamp"

  install -d -m 0700 -- "$state_root" "$checkpoint_dir"

  {
    getfacl -R -p -n -- "$public_root"
    getfacl -R -p -n -- "$inbox_root"
    getfacl -p -n -- "$video_parent"
  } >"$checkpoint_dir/acls.reference"
  chmod 0600 "$checkpoint_dir/acls.reference"

  {
    find "$public_root" -xdev -printf '%p\0%u\0%g\0%m\0%y\0'
    find "$inbox_root" -xdev -printf '%p\0%u\0%g\0%m\0%y\0'
    stat -c '%n\0%u\0%g\0%a\0%F\0' -- "$video_parent"
  } >"$checkpoint_dir/stat-manifest.nul"
  chmod 0600 "$checkpoint_dir/stat-manifest.nul"

  {
    printf '%s\n' \
      "ZFS snapshots from this checkpoint are reference-only." \
      "Do not run zfs rollback while sibling writers are active." \
      "Destroy snapshots only after the agreed rollback window; this script never prunes them." \
      "acls.reference is evidence only; never pass it to setfacl --restore."
    if [[ "$stage" == ownership ]]; then
      printf '%s\n' \
        "Restore only the exact pre-change owners after review with:" \
        "  sudo $checkpoint_dir/ownership.restore.sh"
    fi
    if [[ "$stage" == acls ]]; then
      printf '%s\n' \
        "Restore only UID 237 access/default entries after review with:" \
        "  sudo $checkpoint_dir/acl.restore.sh"
    fi
  } >"$checkpoint_dir/RESTORE.txt"
  chmod 0600 "$checkpoint_dir/RESTORE.txt"

  if [[ "$stage" == ownership ]]; then
    {
      printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
      while IFS= read -r -d '' path; do
        printf 'chown --no-dereference %s:%s -- %q\n' \
          "$legacy_uid" "$legacy_gid" "$path"
      done < <(
        find "$public_root" -xdev -uid "$legacy_uid" -gid "$legacy_gid" -print0
        find "$inbox_root" -xdev -uid "$legacy_uid" -gid "$legacy_gid" -print0
      )
    } >"$checkpoint_dir/ownership.restore.sh"
    chmod 0700 "$checkpoint_dir/ownership.restore.sh"
    bash -n "$checkpoint_dir/ownership.restore.sh"
  fi

  if [[ "$stage" == acls ]]; then
    {
      printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
      for root in "$public_root" "$inbox_root"; do
        while IFS= read -r -d '' path; do
          acl=$(getfacl -c -p -n -- "$path" 2>/dev/null)
          access_perm=$(
            awk -F: '$1 == "user" && $2 == "237" {
              split($3, parts, /[[:space:]]/); print parts[1]; exit
            }' <<<"$acl"
          )
          default_perm=$(
            awk -F: '$1 == "default" && $2 == "user" && $3 == "237" {
              split($4, parts, /[[:space:]]/); print parts[1]; exit
            }' <<<"$acl"
          )
          if [[ -n "$access_perm" ]]; then
            printf 'setfacl --no-mask -m user:%s:%s -- %q\n' \
              "$legacy_uid" "$access_perm" "$path"
          fi
          if [[ -n "$default_perm" ]]; then
            printf 'setfacl --no-mask -m default:user:%s:%s -- %q\n' \
              "$legacy_uid" "$default_perm" "$path"
          fi
        done < <(find "$root" -xdev \( -type f -o -type d \) -print0)
      done

      path=$video_parent
      acl=$(getfacl -c -p -n -- "$path")
      access_perm=$(
        awk -F: '$1 == "user" && $2 == "237" {
          split($3, parts, /[[:space:]]/); print parts[1]; exit
        }' <<<"$acl"
      )
      [[ -n "$access_perm" ]] ||
        die "the /tank/Video traversal ACL disappeared during checkpointing"
      printf 'setfacl --no-mask -m user:%s:%s -- %q\n' \
        "$legacy_uid" "$access_perm" "$path"
    } >"$checkpoint_dir/acl.restore.sh"
    chmod 0700 "$checkpoint_dir/acl.restore.sh"
    bash -n "$checkpoint_dir/acl.restore.sh"
    restore_count=$(grep -c '^setfacl ' "$checkpoint_dir/acl.restore.sh")
    [[ "$restore_count" == 4000 ]] ||
      die "ACL restore script contains $restore_count entries, expected 4000"
  fi

  for dataset in tank/Public tank/Video; do
    ! zfs list -H -t snapshot -o name "$dataset@$snapshot_name" \
      >/dev/null 2>&1 ||
      die "snapshot already exists: $dataset@$snapshot_name"
  done
  zfs snapshot "tank/Public@$snapshot_name" "tank/Video@$snapshot_name"

  log "Rollback artifacts: $checkpoint_dir"
  log "Reference-only snapshots: tank/Public@$snapshot_name and tank/Video@$snapshot_name"
}

check_siblings() {
  local unit
  for unit in tank-Public.mount tank-Video.mount container@copyparty.service \
    restic-backups-Public.timer restic-backups-Video.timer; do
    systemctl is-active --quiet "$unit" ||
      die "sibling unit is not active: $unit"
  done

  [[ "$(systemctl show -p Result --value restic-backups-Public.service)" == success ]] ||
    die "the latest Public restic job was not successful"
  [[ "$(systemctl show -p Result --value restic-backups-Video.service)" == success ]] ||
    die "the latest Video restic job was not successful"
  [[ -z "$(systemctl --failed --no-legend --plain)" ]] ||
    die "systemd has failed units"
}

audit() {
  local access defaults
  preconditions
  read -r access defaults < <(acl_counts)

  log "Legacy exact ownership:"
  log "  Public total: $(count_exact_legacy "$public_root")"
  log "  Public/johnw: $(count_exact_legacy "$public_johnw")"
  log "  Video/Inbox: $(count_exact_legacy "$inbox_root")"
  log "Legacy ACL entries:"
  log "  access: $access"
  log "  default: $defaults"
  log "No payload, marker, daemon-state, certificate, secret, or ZFS property was changed."
}

apply_ownership() {
  preconditions
  if [[ "$(count_any_legacy)" == 0 ]]; then
    log "Ownership is already clean; no changes made."
    check_siblings
    return
  fi

  assert_original_ownership_shape
  make_checkpoint ownership

  find "$public_johnw" -xdev -uid "$legacy_uid" -gid "$legacy_gid" \
    -exec chown --no-dereference "$johnw_uid:$public_gid" -- {} +
  chown --no-dereference 0:0 -- "${public_admin_paths[@]}"
  find "$inbox_root" -xdev -uid "$legacy_uid" -gid "$legacy_gid" \
    -exec chown --no-dereference "$johnw_uid:$immich_gid" -- {} +

  assert_payload_ownership_clean
  assert_ownership_targets
  assert_acltype
  check_siblings
  log "Ownership remediation completed and verified."
}

remove_access_acls() {
  local root=$1
  local path
  local acl
  while IFS= read -r -d '' path; do
    acl=$(getfacl -c -p -n -- "$path" 2>/dev/null)
    if grep -q "^user:$legacy_uid:" <<<"$acl"; then
      setfacl --no-mask -x "user:$legacy_uid" -- "$path"
    fi
  done < <(find "$root" -xdev \( -type f -o -type d \) -print0)
}

remove_default_acls() {
  local root=$1
  local path
  local acl
  while IFS= read -r -d '' path; do
    acl=$(getfacl -c -p -n -- "$path" 2>/dev/null)
    if grep -q "^default:user:$legacy_uid:" <<<"$acl"; then
      setfacl --no-mask -x "default:user:$legacy_uid" -- "$path"
    fi
  done < <(find "$root" -xdev -type d -print0)
}

apply_acls() {
  local access defaults
  local pass
  local video_acl
  preconditions
  assert_payload_ownership_clean
  read -r access defaults < <(acl_counts)

  if [[ "$access" == 0 && "$defaults" == 0 ]]; then
    log "Legacy ACLs are already absent; no changes made."
    check_siblings
    return
  fi
  [[ "$access" == 3669 && "$defaults" == 331 ]] ||
    die "legacy ACL counts drifted from the audited 3669 access / 331 default entries"
  video_acl=$(getfacl -c -p -n -- "$video_parent")
  grep -q "^user:$legacy_uid:--x" <<<"$video_acl" ||
    die "the exact /tank/Video traversal ACL drifted"

  make_checkpoint acls
  nonlegacy_acl_dump >"$checkpoint_dir/nonlegacy-before.acl"

  for pass in 1 2 3; do
    log "ACL removal pass $pass"
    remove_default_acls "$public_root"
    remove_default_acls "$inbox_root"
    remove_access_acls "$public_root"
    remove_access_acls "$inbox_root"

    video_acl=$(getfacl -c -p -n -- "$video_parent")
    if grep -q "^user:$legacy_uid:" <<<"$video_acl"; then
      setfacl --no-mask -x "user:$legacy_uid" -- "$video_parent"
    fi

    read -r access defaults < <(acl_counts)
    [[ "$access" == 0 && "$defaults" == 0 ]] && break
  done

  [[ "$access" == 0 && "$defaults" == 0 ]] ||
    die "legacy ACL entries remain after three bounded passes"

  nonlegacy_acl_dump >"$checkpoint_dir/nonlegacy-after.acl"
  cmp -s "$checkpoint_dir/nonlegacy-before.acl" \
    "$checkpoint_dir/nonlegacy-after.acl" ||
    die "a non-legacy ACL or concurrent filesystem entry changed; inspect rollback artifacts"

  assert_acltype
  check_siblings
  log "ACL remediation completed and verified."
}

mode=${1:-}
confirmation=${2:-}

case "$mode" in
  audit)
    [[ -z "$confirmation" ]] || die "audit takes no confirmation argument"
    audit
    ;;
  apply-ownership)
    [[ "$confirmation" == --yes ]] || die "apply-ownership requires --yes"
    apply_ownership
    ;;
  apply-acls)
    [[ "$confirmation" == --yes ]] || die "apply-acls requires --yes"
    apply_acls
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
