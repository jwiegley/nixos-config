# Open WebUI - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/open-webui.nix)
# This file: Nginx virtual host, SOPS secrets, PostgreSQL user setup, and tmpfiles
# (no firewall rules — the container uses host networking, see the note at the
# bottom of this file)

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  common = import ../lib/common.nix { inherit secrets; };
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # Set up PostgreSQL password for open_webui user
    (mkPostgresUserSetup {
      user = "open_webui";
      database = "open_webui";
      secretPath = config.sops.secrets."open-webui-db-password".path;
      dependentService = "podman-open-webui.service";
    })
  ];

  # Nginx virtual host
  services.nginx.virtualHosts."chat.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/chat.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/chat.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8084/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
        proxy_read_timeout 2h;
        proxy_connect_timeout 60s;
        proxy_send_timeout 2h;
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };
  };

  # SOPS secrets
  sops.secrets."open-webui-secrets" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "open-webui";
    path = "/run/secrets-open-webui/open-webui-secrets";
  };

  # Hermes agent key, composed at activation rather than declared.
  #
  # Open WebUI takes multiple OpenAI-compatible backends as semicolon-joined
  # OPENAI_API_BASE_URLS / OPENAI_API_KEYS, matched positionally. The URLs are
  # not secret and live in open-webui.nix; the KEYS list contains Hermes'
  # API_SERVER_KEY and so must never reach the world-readable Nix store.
  #
  # That key exists only inside the multi-line `hermes/env` SOPS entry, so it
  # cannot be addressed with sops.placeholder (there is no YAML sub-path into an
  # env-file blob) and cannot be rendered with sops.templates. Rather than
  # require a new secrets.yaml entry, this oneshot extracts the single line at
  # activation and writes a keys file only open-webui can read -- the same
  # pattern rspamd.nix uses to build its gpt.conf. Nothing is decrypted that
  # sops-nix has not already decrypted, and the value never appears in a unit
  # definition, a store path, or a log.
  #
  # The FIRST list element is a placeholder on purpose: the :4000 gateway
  # injects its own upstream Authorization header and discards whatever the
  # client sends, so a real key there would be meaningless. What matters is
  # positional alignment with OPENAI_API_BASE_URLS in open-webui.nix --
  # KEEP THE TWO LISTS IN THE SAME ORDER.
  systemd.services.open-webui-compose-keys = {
    description = "Compose Open WebUI's OPENAI_API_KEYS from SOPS";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      set -euo pipefail
      src=${config.sops.secrets."hermes/env".path}
      out=/run/secrets-open-webui/hermes-openai-keys

      # ALWAYS write the file, even on failure: open-webui lists it in
      # environmentFiles, and podman refuses to start if the path is missing.
      # An empty second key degrades to "Hermes backend present but
      # unauthenticated" (it will 401), which is visible and recoverable --
      # unlike a container that will not boot.
      key=""
      if [ -r "$src" ]; then
        key="$(${pkgs.gnugrep}/bin/grep -m1 '^API_SERVER_KEY=' "$src" | ${pkgs.coreutils}/bin/cut -d= -f2- || true)"
      fi
      if [ -z "$key" ]; then
        echo "API_SERVER_KEY unavailable; the Hermes backend will 401 until this is fixed" >&2
      fi

      ${pkgs.coreutils}/bin/install -d -m 0750 -o open-webui -g open-webui /run/secrets-open-webui
      umask 0077
      printf 'OPENAI_API_KEYS=%s;%s\n' 'gateway-injects-real-key' "$key" > "$out"
      ${pkgs.coreutils}/bin/chown open-webui:open-webui "$out"
      ${pkgs.coreutils}/bin/chmod 0400 "$out"
    '';
  };
  sops.secrets."open-webui-db-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "open-webui";
  };

  # tmpfiles rules - use 'd' directive (preserves contents) for persistent data
  systemd.tmpfiles.rules = [
    "d /var/lib/containers/open-webui/data 0755 open-webui open-webui -"
  ];

  # No firewall rules needed - using host networking mode
}
