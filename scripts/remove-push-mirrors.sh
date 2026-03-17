#!/usr/bin/env bash
# One-time script to remove all push mirrors from Gitea repositories.
# Run as: sudo systemd-run --pipe -p EnvironmentFile=/run/secrets-rendered/github-mirror-env \
#           -E GITEA_URL=https://gitea.vulcan.lan -E GITEA_USER=johnw \
#           /etc/nixos/scripts/remove-push-mirrors.sh
#
# Or source the env vars manually and run directly.

set -euo pipefail

GITEA_TOKEN="${GITEA_TOKEN:-}"
GITEA_URL="${GITEA_URL:-https://gitea.vulcan.lan}"
GITEA_USER="${GITEA_USER:-johnw}"

if [ -z "$GITEA_TOKEN" ]; then
  echo "ERROR: GITEA_TOKEN is not set" >&2
  exit 1
fi

echo "Removing push mirrors from all repos owned by $GITEA_USER on $GITEA_URL"
echo ""

removed=0
failed=0
page=1

while true; do
  repos=$(curl -sSf -H "Authorization: token $GITEA_TOKEN" \
    "$GITEA_URL/api/v1/repos/search?owner=$GITEA_USER&limit=50&page=$page&mirror=true" \
    | jq -r '.data // [] | .[].name' 2>/dev/null)

  if [ -z "$repos" ]; then
    break
  fi

  while IFS= read -r repo_name; do
    # List push mirrors for this repo
    mirrors=$(curl -sSf -H "Authorization: token $GITEA_TOKEN" \
      "$GITEA_URL/api/v1/repos/$GITEA_USER/$repo_name/push_mirrors" 2>/dev/null || echo "[]")

    mirror_names=$(echo "$mirrors" | jq -r '.[] | .remote_name' 2>/dev/null)

    if [ -z "$mirror_names" ]; then
      continue
    fi

    while IFS= read -r mirror_name; do
      [ -z "$mirror_name" ] && continue

      http_code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: token $GITEA_TOKEN" \
        "$GITEA_URL/api/v1/repos/$GITEA_USER/$repo_name/push_mirrors/$mirror_name")

      if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "  ✓ Removed push mirror from: $repo_name ($mirror_name)"
        removed=$((removed + 1))
      else
        echo "  ✗ Failed to remove push mirror from: $repo_name ($mirror_name) - HTTP $http_code" >&2
        failed=$((failed + 1))
      fi
    done <<< "$mirror_names"
  done <<< "$repos"

  page=$((page + 1))
done

echo ""
echo "Done. Removed: $removed, Failed: $failed"
