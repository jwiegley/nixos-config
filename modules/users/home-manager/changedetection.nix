{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.changedetection =
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
      home.username = "changedetection";
      home.homeDirectory = "/var/lib/containers/changedetection";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
      ];

      virtualisation.quadlet.containers.changedetection = {
        autoStart = true;

        containerConfig = {
          image = "ghcr.io/dgtlmoon/changedetection.io:latest";
          publishPorts = [ "127.0.0.1:5055:5000/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          # Use json-file log driver to keep logs in container files instead of flooding journald
          # Health check logs from Prometheus blackbox exporter occur every minute
          logDriver = "json-file";

          environments = {
            PORT = "5000";
            BASE_URL = "https://changes.vulcan.lan";
            PLAYWRIGHT_DRIVER_URL = "ws://10.0.2.2:3008";
            FETCH_WORKERS = "10";
            LOGGER_LEVEL = "INFO";
            TZ = "America/Los_Angeles";
          };

          environmentFiles = [ "/run/secrets-changedetection/changedetection/api-key" ];

          volumes = [
            "/var/lib/changedetection:/datastore:rw"
          ];
        };

        unitConfig = {
          After = [
            "network-online.target"
            "sockpuppetbrowser.service"
          ];
          Requires = [ "sockpuppetbrowser.service" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "900";
        };
      };

      virtualisation.quadlet.containers.sockpuppetbrowser = {
        autoStart = true;

        containerConfig = {
          image = "dgtlmoon/sockpuppetbrowser:latest";
          publishPorts = [ "127.0.0.1:3008:3000/tcp" ];
          networks = [ "slirp4netns" ];

          logDriver = "json-file";

          environments = {
            SCREEN_WIDTH = "1920";
            SCREEN_HEIGHT = "1024";
            SCREEN_DEPTH = "16";
            MAX_CONCURRENT_CHROME_PROCESSES = "10";
          };
        };

        unitConfig = {
          After = [ "network-online.target" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "300";
        };
      };
    };
}
