{
  config,
  lib,
  pkgs,
  ...
}:

let
  publishDir = "/var/lib/calendar-publisher";
  port = 8090;
  hostname = "calendar.newartisans.com";
  tunnelId = "ee15f9a4-a847-4d5a-90ab-6338eca646ec";
  tunnelTarget = "${tunnelId}.cfargotunnel.com";
in
{
  # Sacramento Cluster calendar publisher.
  #
  # Daily timer regenerates per-column .ics files from the public Google
  # Sheet via the sac-cluster-ics CLI. Files land in /var/lib/calendar-publisher
  # and are served by nginx on a localhost port that the existing
  # cloudflared "data" tunnel maps to calendar.newartisans.com.
  #
  # Subscribers add e.g. https://calendar.newartisans.com/florin.ics in any
  # calendar app. The CLI emits stable UIDs so re-runs update events in
  # place rather than duplicating them.

  sops.secrets."cloudflared/api_token" = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "calendar-publisher-dns.service" ];
  };

  users.users.calendar-publisher = {
    isSystemUser = true;
    group = "calendar-publisher";
    description = "Sacramento Cluster .ics generator";
  };
  users.groups.calendar-publisher = { };

  systemd.tmpfiles.rules = [
    "d ${publishDir} 0755 calendar-publisher calendar-publisher - -"
  ];

  systemd.services.calendar-publisher = {
    description = "Generate Sacramento Cluster .ics calendar files";
    serviceConfig = {
      Type = "oneshot";
      User = "calendar-publisher";
      Group = "calendar-publisher";
      ExecStart = "${pkgs.sac-cluster-ics}/bin/sac-cluster-ics --per-column ${publishDir}/";

      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      ReadWritePaths = [ publishDir ];
    };
  };

  systemd.timers.calendar-publisher = {
    description = "Daily refresh of Sacramento Cluster calendars";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  # One-shot service: ensure the public CNAME record exists in Cloudflare,
  # pointing calendar.newartisans.com at the data tunnel. Idempotent — looks
  # up the record first and only POSTs if missing. Runs on every nixos-rebuild
  # switch (via wantedBy multi-user.target) so a fresh box bootstraps itself.
  systemd.services.calendar-publisher-dns =
    let
      ensureScript = pkgs.writeShellApplication {
        name = "calendar-publisher-ensure-dns";
        runtimeInputs = with pkgs; [
          curl
          jq
        ];
        text = ''
          set -euo pipefail
          token=$(cat "$CREDENTIALS_DIRECTORY/api_token")
          api="https://api.cloudflare.com/client/v4"

          # Resolve the zone id for newartisans.com once.
          zone_id=$(curl -fsS -H "Authorization: Bearer $token" \
            "$api/zones?name=newartisans.com" | jq -r '.result[0].id')
          if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then
            echo "could not resolve newartisans.com zone id" >&2
            exit 1
          fi

          # Look up any existing record for the hostname.
          existing=$(curl -fsS -H "Authorization: Bearer $token" \
            "$api/zones/$zone_id/dns_records?name=${hostname}" \
            | jq -r '.result[0]')

          desired_content="${tunnelTarget}"

          if [ "$existing" = "null" ]; then
            echo "creating CNAME ${hostname} -> $desired_content"
            curl -fsS -X POST \
              -H "Authorization: Bearer $token" \
              -H "Content-Type: application/json" \
              "$api/zones/$zone_id/dns_records" \
              -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"$desired_content\",\"proxied\":true,\"ttl\":1}" \
              | jq -r '.success'
          else
            id=$(echo "$existing" | jq -r '.id')
            current=$(echo "$existing" | jq -r '.content')
            proxied=$(echo "$existing" | jq -r '.proxied')
            if [ "$current" = "$desired_content" ] && [ "$proxied" = "true" ]; then
              echo "CNAME ${hostname} already correct; nothing to do"
            else
              echo "updating CNAME ${hostname}: $current -> $desired_content"
              curl -fsS -X PUT \
                -H "Authorization: Bearer $token" \
                -H "Content-Type: application/json" \
                "$api/zones/$zone_id/dns_records/$id" \
                -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"$desired_content\",\"proxied\":true,\"ttl\":1}" \
                | jq -r '.success'
            fi
          fi
        '';
      };
    in
    {
      description = "Ensure Cloudflare DNS for ${hostname}";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${ensureScript}/bin/calendar-publisher-ensure-dns";
        LoadCredential = "api_token:${config.sops.secrets."cloudflared/api_token".path}";

        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

  services.nginx.virtualHosts.${hostname} = {
    listen = [
      {
        addr = "127.0.0.1";
        port = port;
      }
    ];
    root = publishDir;
    extraConfig = ''
      types { text/calendar ics; }
      default_type application/octet-stream;
      autoindex off;
    '';
    locations."/" = {
      extraConfig = ''
        # 15-min edge TTL: matches Apple Calendar's poll cadence while
        # absorbing thundering-herd polls. Google polls ~24h regardless.
        add_header Cache-Control "public, max-age=900, stale-while-revalidate=3600";
        try_files $uri =404;
      '';
    };
  };
}
