#!/usr/bin/env bash
#
# Restore push mirrors for Gitea-primary repositories.
# These are repos that do NOT have a pull mirror (mirror=false) but should
# push to GitHub. Repos with pull mirrors are GitHub-primary and should
# NOT get push mirrors.
#
# Run as:
#   sudo systemd-run --pipe \
#     -p EnvironmentFile=/run/secrets-rendered/github-mirror-env \
#     -E GITEA_URL=https://gitea.vulcan.lan \
#     -E GITEA_USER=johnw \
#     -E GITHUB_USER=jwiegley \
#     -E MIRROR_INTERVAL=8h \
#     /etc/nixos/scripts/restore-push-mirrors.sh

set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
GITEA_URL="${GITEA_URL:-https://gitea.vulcan.lan}"
GITEA_USER="${GITEA_USER:-johnw}"
GITHUB_USER="${GITHUB_USER:-jwiegley}"
MIRROR_INTERVAL="${MIRROR_INTERVAL:-8h}"
SYNC_ON_COMMIT=false

if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITEA_TOKEN" ]; then
  echo "ERROR: GITHUB_TOKEN and GITEA_TOKEN must be set" >&2
  exit 1
fi

echo "Restoring push mirrors for Gitea-primary repositories"
echo "Gitea user: $GITEA_USER → GitHub user: $GITHUB_USER"
echo ""

added=0
skipped=0
already=0
failed=0
page=1

while true; do
  # Fetch NON-mirror repos (Gitea-primary)
  repos=$(curl -sSfk -H "Authorization: token $GITEA_TOKEN" \
    "$GITEA_URL/api/v1/users/$GITEA_USER/repos?page=$page&limit=50" 2>/dev/null || echo "[]")

  count=$(echo "$repos" | jq 'length')
  [ "$count" -eq 0 ] && break

  while read -r repo; do
    repo_name=$(echo "$repo" | jq -r '.name')
    is_mirror=$(echo "$repo" | jq -r '.mirror')

    # Skip pull mirrors — those are GitHub-primary
    if [ "$is_mirror" = "true" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    # Skip private repos and specific exclusions
    is_private=$(echo "$repo" | jq -r '.private')
    if [ "$is_private" = "true" ]; then
      echo "  → Private, skipping: $repo_name"
      skipped=$((skipped + 1))
      continue
    fi

    case "$repo_name" in
      srp-db)
        echo "  → Excluded: $repo_name"
        skipped=$((skipped + 1))
        continue
        ;;
    esac

    # Check if push mirror already exists
    existing=$(curl -sSfk -H "Authorization: token $GITEA_TOKEN" \
      "$GITEA_URL/api/v1/repos/$GITEA_USER/$repo_name/push_mirrors" 2>/dev/null || echo "[]")

    if [ "$(echo "$existing" | jq 'length')" -gt 0 ]; then
      echo "  → Already has push mirror: $repo_name"
      already=$((already + 1))
      continue
    fi

    # Check if GitHub repo exists
    gh_status=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/repos/$GITHUB_USER/$repo_name" 2>/dev/null)

    if [ "$gh_status" != "200" ]; then
      echo "  → No GitHub repo: $repo_name (skipping)"
      skipped=$((skipped + 1))
      continue
    fi

    # Add push mirror
    payload=$(jq -n \
      --arg remote_address "https://github.com/$GITHUB_USER/$repo_name.git" \
      --arg remote_username "$GITHUB_USER" \
      --arg remote_password "$GITHUB_TOKEN" \
      --arg interval "$MIRROR_INTERVAL" \
      --argjson sync_on_commit "$SYNC_ON_COMMIT" \
      '{
        remote_address: $remote_address,
        remote_username: $remote_username,
        remote_password: $remote_password,
        interval: $interval,
        sync_on_commit: $sync_on_commit
      }')

    http_code=$(curl -sSk -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Authorization: token $GITEA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$GITEA_URL/api/v1/repos/$GITEA_USER/$repo_name/push_mirrors" 2>/dev/null)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
      echo "  ✓ Added push mirror: $repo_name → github.com/$GITHUB_USER/$repo_name"
      added=$((added + 1))
    else
      echo "  ✗ Failed: $repo_name (HTTP $http_code)" >&2
      failed=$((failed + 1))
    fi
  done < <(echo "$repos" | jq -c '.[]')

  page=$((page + 1))
done

echo ""
echo "Done. Added: $added, Already had: $already, Skipped: $skipped, Failed: $failed"
