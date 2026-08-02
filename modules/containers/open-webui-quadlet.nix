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

            # ---- Reconcile the backend list in Open WebUI's DATABASE ----
            # Setting OPENAI_API_BASE_URLS / OPENAI_API_KEYS in the container
            # environment is NOT sufficient. Open WebUI marks both as PersistentConfig:
            # the values live in its `config` table, the env var seeds them only on the
            # very first start, and thereafter the database wins and the env is
            # ignored. An earlier attempt set only the env vars and had no effect --
            # the second backend never appeared and the model picker showed nothing but
            # the built-in "Arena Model".
            #
            # So the list is written here instead. The URLs are not secret, but the
            # keys array contains Hermes' API_SERVER_KEY, which is why this cannot live
            # in the SQL reconciler in open-webui.nix: that renders into a unit script
            # and therefore into the world-readable Nix store. Here the key is read
            # from SOPS at activation and passed to psql on STDIN -- never in argv,
            # where `ps` would expose it.
            #
            # Index 0 is the LLM gateway (nginx injects its own upstream key, so the
            # placeholder is correct); index 1 is the Hermes agent.
            if ${pkgs.util-linux}/bin/runuser -u postgres -- \
                 ${pkgs.postgresql}/bin/psql -Atq -d open_webui -c \
                 "SELECT 1 FROM information_schema.tables WHERE table_name='config'" >/dev/null 2>&1; then
              ${pkgs.util-linux}/bin/runuser -u postgres -- \
                ${pkgs.postgresql}/bin/psql -q -v ON_ERROR_STOP=1 -d open_webui <<SQL || \
                  echo "open_webui backend reconcile failed (non-fatal)" >&2
              INSERT INTO config (key, value, updated_at) VALUES
                ('openai.api_base_urls',
                 -- hermes-vm is an /etc/hosts name published by hermes-microvm.nix
                 -- from its vmAddr binding; 8080 must match apiServerPort in that
                 -- same file. NOT 127.0.0.1:8080 -- nothing listens there.
                 '["http://127.0.0.1:4000/v1","http://hermes-vm:8080/v1"]'::json,
                 extract(epoch FROM now())::bigint),
                ('openai.api_keys',
                 json_build_array('gateway-injects-real-key', \$hermes\$$key\$hermes\$),
                 extract(epoch FROM now())::bigint),
                ('openai.api_configs',
                 '{"0":{"enable":true},"1":{"enable":true}}'::json,
                 extract(epoch FROM now())::bigint),
                ('openai.enable', 'true'::json, extract(epoch FROM now())::bigint),
                -- Stale ordering from the LiteLLM era listed models that no longer
                -- exist (hera/gpt-oss-*, positron/*), which is why the picker looked
                -- empty. Emptying it lets Open WebUI fall back to natural ordering.
                ('ui.model_order_list', '[]'::json, extract(epoch FROM now())::bigint)
              ON CONFLICT (key) DO UPDATE SET
                value = EXCLUDED.value,
                updated_at = EXCLUDED.updated_at
              WHERE config.value::jsonb IS DISTINCT FROM EXCLUDED.value::jsonb;
      SQL
            else
              echo "open_webui config table not ready; backends will reconcile on the next run" >&2
            fi
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
