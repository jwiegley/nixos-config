{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.opnsense-exporter =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];

      home.stateVersion = "24.11";
      home.username = "opnsense-exporter";
      home.homeDirectory = "/var/lib/containers/opnsense-exporter";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
      ];

      virtualisation.quadlet.containers.opnsense-exporter = {
        autoStart = true;

        containerConfig = {
          image = "ghcr.io/athennamind/opnsense-exporter:latest";
          publishPorts = [ "127.0.0.1:9273:8080/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          environments = {
            OPNSENSE_EXPORTER_OPS_PROTOCOL = "http";
            OPNSENSE_EXPORTER_OPS_API = "10.88.0.1:8444";
            OPNSENSE_EXPORTER_OPS_INSECURE = "true";
            OPNSENSE_EXPORTER_INSTANCE_LABEL = "opnsense-router";
            # Kea DHCPv4/v6 collectors fail with "cannot unmarshal array into
            # Go struct field KeaDhcpv*LeasesResponse.Interfaces of type
            # map[string]string" — OPNsense returns Interfaces as [] but the
            # exporter expects {}. No upstream fix as of v0.0.10/11; no
            # dashboards consume these metrics. Re-enable when upstream ships
            # a schema fix.
            OPNSENSE_EXPORTER_DISABLE_KEADHCPV4 = "true";
            OPNSENSE_EXPORTER_DISABLE_KEADHCPV6 = "true";
          };

          environmentFiles = [ "/run/secrets-opnsense-exporter/opnsense-exporter-secrets" ];

          exec = "--log.level=info --log.format=json --web.listen-address=:8080";
        };

        unitConfig = {
          After = [
            "sops-nix.service"
            "opnsense-api-transformer.service"
          ];
          Wants = [
            "sops-nix.service"
            "opnsense-api-transformer.service"
          ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "900";
        };
      };
    };
}
