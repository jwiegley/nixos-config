{ config, lib, pkgs, ... }:

let
  cfg = config.services.github-gitea-mirror;

  mirrorScript = pkgs.writeShellApplication {
    name = "github-gitea-mirror";
    runtimeInputs = with pkgs; [ curl jq coreutils ];
    text = ''
      set -euo pipefail

      # Load configuration from environment
      GITHUB_TOKEN="''${GITHUB_TOKEN:-}"
      GITEA_TOKEN="''${GITEA_TOKEN:-}"
      GITEA_URL="''${GITEA_URL:-}"
      GITHUB_USER="''${GITHUB_USER:-}"
      GITEA_USER="''${GITEA_USER:-}"
      MIRROR_INTERVAL="''${MIRROR_INTERVAL:-}"

      # Validate required environment variables
      if [ -z "$GITHUB_TOKEN" ]; then
        echo "ERROR: GITHUB_TOKEN is not set" >&2
        exit 1
      fi

      if [ -z "$GITEA_TOKEN" ]; then
        echo "ERROR: GITEA_TOKEN is not set" >&2
        exit 1
      fi

      echo "Starting GitHub to Gitea mirror discovery"
      echo "GitHub user: $GITHUB_USER"
      echo "Gitea user: $GITEA_USER"
      echo "Gitea URL: $GITEA_URL"
      echo "Mirror sync interval: $MIRROR_INTERVAL seconds"
      echo ""

      # Fetch Gitea user ID
      echo "Fetching Gitea user ID for $GITEA_USER..."
      GITEA_UID=$(curl -sSf -H "Authorization: token $GITEA_TOKEN" \
        "$GITEA_URL/api/v1/users/$GITEA_USER" | jq -r '.id')

      if [ -z "$GITEA_UID" ] || [ "$GITEA_UID" = "null" ]; then
        echo "ERROR: Failed to fetch Gitea user ID for $GITEA_USER" >&2
        exit 1
      fi

      echo "Gitea user ID: $GITEA_UID"
      echo ""

      # Track statistics
      total_repos=0
      created_count=0
      existing_count=0
      skipped_count=0
      failed_count=0

      # Paginate through GitHub repositories
      page=1
      while true; do
        echo "Fetching GitHub repositories (page $page)..."

        # Fetch only owner repos (excludes forks by default)
        repos=$(curl -sSf -H "Authorization: token $GITHUB_TOKEN" \
          "https://api.github.com/user/repos?per_page=100&page=$page&type=owner&sort=updated" || echo "[]")

        # Break if no more repos
        repo_count=$(echo "$repos" | jq 'length')
        if [ "$repo_count" -eq 0 ]; then
          echo "No more repositories found"
          break
        fi

        echo "Processing $repo_count repositories..."

        # Filter out archived and forked repos, then process each
        # Use process substitution to avoid subshell variable scope issues
        while read -r repo; do
          clone_url=$(echo "$repo" | jq -r '.clone_url')
          repo_name=$(echo "$repo" | jq -r '.name')
          description=$(echo "$repo" | jq -r '.description // ""' | cut -c1-255)

          total_repos=$((total_repos + 1))

          # Create JSON payload using jq for proper escaping
          payload=$(jq -n \
            --arg clone_addr "$clone_url" \
            --arg repo_name "$repo_name" \
            --arg description "$description" \
            --arg mirror_interval "$MIRROR_INTERVAL" \
            --argjson uid "$GITEA_UID" \
            '{
              clone_addr: $clone_addr,
              repo_name: $repo_name,
              description: $description,
              mirror: true,
              mirror_interval: $mirror_interval,
              private: false,
              uid: $uid
            }')

          # Create pull mirror in Gitea
          result=$(curl -sS -w "\n%{http_code}" \
            -H "Authorization: token $GITEA_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$GITEA_URL/api/v1/repos/migrate" 2>&1)

          http_code=$(echo "$result" | tail -n1)
          response_body=$(echo "$result" | head -n-1)

          case "$http_code" in
            201)
              echo "  ✓ Created pull mirror: $repo_name"
              created_count=$((created_count + 1))

              # Also add push mirror for bidirectional sync
              push_payload=$(jq -n \
                --arg remote_address "$clone_url" \
                --arg remote_username "$GITHUB_USER" \
                --arg remote_password "$GITHUB_TOKEN" \
                --arg interval "$MIRROR_INTERVAL" \
                '{
                  remote_address: $remote_address,
                  remote_username: $remote_username,
                  remote_password: $remote_password,
                  interval: $interval,
                  sync_on_commit: false
                }')

              push_result=$(curl -sS -w "\n%{http_code}" \
                -X POST \
                -H "Authorization: token $GITEA_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$push_payload" \
                "$GITEA_URL/api/v1/repos/$GITEA_USER/$repo_name/push_mirrors" 2>&1)

              push_http_code=$(echo "$push_result" | tail -n1)

              if [ "$push_http_code" = "200" ]; then
                echo "    ✓ Added push mirror: $repo_name"
              else
                echo "    ✗ Failed to add push mirror: $repo_name (HTTP $push_http_code)" >&2
              fi
              ;;
            409)
              echo "  → Already exists: $repo_name"
              existing_count=$((existing_count + 1))
              ;;
            *)
              echo "  ✗ Failed to mirror: $repo_name (HTTP $http_code)" >&2
              echo "    Response: $response_body" >&2
              failed_count=$((failed_count + 1))
              ;;
          esac
        done < <(echo "$repos" | jq -c '.[] | select(.archived == false and .fork == false)')

        # Check if we filtered out repos (archived or forked)
        filtered_count=$(echo "$repos" | jq '[.[] | select(.archived == true or .fork == true)] | length')
        if [ "$filtered_count" -gt 0 ]; then
          echo "Skipped $filtered_count archived/forked repositories on this page"
          skipped_count=$((skipped_count + filtered_count))
        fi

        page=$((page + 1))
        echo ""
      done

      echo "========================================="
      echo "Mirror discovery completed"
      echo "========================================="
      echo "Repositories processed: $total_repos"
      echo "Mirrors created: $created_count"
      echo "Already existing: $existing_count"
      echo "Skipped (archived/forked): $skipped_count"
      echo "Failed: $failed_count"
      echo "========================================="

      if [ "$failed_count" -gt 0 ]; then
        echo "WARNING: Some repositories failed to mirror" >&2
        exit 1
      fi
    '';
  };
in
{
  options.services.github-gitea-mirror = {
    enable = lib.mkEnableOption "GitHub to Gitea repository mirroring";

    githubUser = lib.mkOption {
      type = lib.types.str;
      default = "jwiegley";
      description = "GitHub username to mirror repositories from";
    };

    giteaUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://gitea.vulcan.lan";
      description = "Gitea instance URL (without trailing slash)";
    };

    giteaUser = lib.mkOption {
      type = lib.types.str;
      default = "johnw";
      description = "Gitea user to create repositories under";
    };

    mirrorInterval = lib.mkOption {
      type = lib.types.str;
      default = "8h";
      description = "Interval for Gitea to sync mirrors (Go duration format: 8h, 4h, 1h30m, etc.)";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 03:00:00";
      description = "When to run discovery (systemd OnCalendar format)";
    };
  };

  config = lib.mkIf cfg.enable {
    # SOPS secrets for GitHub and Gitea tokens
    sops.secrets = {
      "github-mirror-token" = {
        mode = "0400";
        owner = "root";
      };
      "gitea-mirror-token" = {
        mode = "0400";
        owner = "root";
      };
    };

    # Template for environment file with tokens
    sops.templates."github-mirror-env" = {
      content = ''
        GITHUB_TOKEN=${config.sops.placeholder."github-mirror-token"}
        GITEA_TOKEN=${config.sops.placeholder."gitea-mirror-token"}
      '';
      mode = "0400";
      owner = "root";
    };

    # Systemd service for repository discovery and mirroring
    systemd.services.github-mirror = {
      description = "Discover and mirror GitHub repositories to Gitea";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe mirrorScript;
        User = "root";
        StandardOutput = "journal";
        StandardError = "journal";
        # Load secrets from SOPS template
        EnvironmentFile = config.sops.templates."github-mirror-env".path;
      };

      # Configuration environment variables
      environment = {
        GITEA_URL = cfg.giteaUrl;
        GITHUB_USER = cfg.githubUser;
        GITEA_USER = cfg.giteaUser;
        MIRROR_INTERVAL = cfg.mirrorInterval;
      };

      path = with pkgs; [ curl jq coreutils ];

      # Ensure network is available
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    };

    # Systemd timer for periodic execution
    systemd.timers.github-mirror = {
      description = "Timer for GitHub to Gitea repository mirroring";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };
  };
}
