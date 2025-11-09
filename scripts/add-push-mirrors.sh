#!/usr/bin/env bash
#
# One-time script to add push mirrors to all existing Gitea mirrors
# This configures bidirectional mirroring (pull from GitHub, push to GitHub)
#

set -euo pipefail

# Configuration
GITEA_URL="https://gitea.vulcan.lan"
GITEA_USER="johnw"
GITHUB_USER="jwiegley"
MIRROR_INTERVAL="8h"  # Go duration format
SYNC_ON_COMMIT=false

# Load tokens from SOPS
GITEA_TOKEN=$(sudo cat /run/secrets/gitea-mirror-token)
GITHUB_TOKEN=$(sudo cat /run/secrets/github-mirror-token)

if [ -z "$GITEA_TOKEN" ]; then
  echo "ERROR: Failed to load gitea-mirror-token from SOPS" >&2
  exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
  echo "ERROR: Failed to load github-mirror-token from SOPS" >&2
  exit 1
fi

echo "========================================="
echo "Adding push mirrors to existing Gitea repositories"
echo "========================================="
echo "Gitea user: $GITEA_USER"
echo "GitHub user: $GITHUB_USER"
echo "Gitea URL: $GITEA_URL"
echo "Push interval: $MIRROR_INTERVAL"
echo ""

# Track statistics
total_repos=0
push_added=0
already_has_push=0
skipped_count=0
failed_count=0

# Paginate through Gitea repositories
page=1
while true; do
  echo "Fetching Gitea repositories (page $page)..."

  repos=$(curl -sSfk -H "Authorization: token $GITEA_TOKEN" \
    "$GITEA_URL/api/v1/users/$GITEA_USER/repos?page=$page&limit=50" || echo "[]")

  repo_count=$(echo "$repos" | jq 'length')
  if [ "$repo_count" -eq 0 ]; then
    echo "No more repositories found"
    break
  fi

  echo "Processing $repo_count repositories..."

  # Process each repository
  while read -r repo; do
    repo_name=$(echo "$repo" | jq -r '.name')
    is_mirror=$(echo "$repo" | jq -r '.mirror')

    total_repos=$((total_repos + 1))

    # Skip the "org" repository (not a GitHub mirror)
    if [ "$repo_name" = "org" ]; then
      echo "  → Skipping: $repo_name (not a GitHub mirror)"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Only process mirrors
    if [ "$is_mirror" != "true" ]; then
      echo "  → Skipping: $repo_name (not a mirror)"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Check if push mirror already exists
    existing_push=$(curl -sSfk -H "Authorization: token $GITEA_TOKEN" \
      "$GITEA_URL/api/v1/repos/$GITEA_USER/$repo_name/push_mirrors" || echo "[]")

    existing_count=$(echo "$existing_push" | jq 'length')
    if [ "$existing_count" -gt 0 ]; then
      echo "  → Already has push mirror: $repo_name"
      already_has_push=$((already_has_push + 1))
      continue
    fi

    # Create push mirror payload
    github_url="https://github.com/$GITHUB_USER/$repo_name.git"

    payload=$(jq -n \
      --arg remote_address "$github_url" \
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

    # Add push mirror
    result=$(curl -sSk -w "\n%{http_code}" \
      -X POST \
      -H "Authorization: token $GITEA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$GITEA_URL/api/v1/repos/$GITEA_USER/$repo_name/push_mirrors" 2>&1)

    http_code=$(echo "$result" | tail -n1)
    response_body=$(echo "$result" | head -n-1)

    case "$http_code" in
      200)
        echo "  ✓ Added push mirror: $repo_name"
        push_added=$((push_added + 1))
        ;;
      *)
        echo "  ✗ Failed to add push mirror: $repo_name (HTTP $http_code)" >&2
        echo "    Response: $response_body" >&2
        failed_count=$((failed_count + 1))
        ;;
    esac

  done < <(echo "$repos" | jq -c '.[]')

  page=$((page + 1))
  echo ""
done

echo "========================================="
echo "Push mirror setup completed"
echo "========================================="
echo "Repositories processed: $total_repos"
echo "Push mirrors added: $push_added"
echo "Already had push mirrors: $already_has_push"
echo "Skipped (non-mirrors): $skipped_count"
echo "Failed: $failed_count"
echo "========================================="

if [ "$failed_count" -gt 0 ]; then
  echo "WARNING: Some push mirrors failed to add" >&2
  exit 1
fi
