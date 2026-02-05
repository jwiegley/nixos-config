# LastSignal - Rootless Quadlet Container Configuration
# Dead man's switch for delivering encrypted messages

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.lastsignal =
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
      home.username = "lastsignal";
      home.homeDirectory = "/var/lib/containers/lastsignal";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
      ];

      virtualisation.quadlet.containers.lastsignal = {
        autoStart = true;

        containerConfig = {
          image = "localhost/lastsignal:latest";
          publishPorts = [ "127.0.0.1:8190:80/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          environments = {
            RAILS_ENV = "production";
            APP_BASE_URL = "https://lastsignal.vulcan.lan";
            APP_HOST = "lastsignal.vulcan.lan";
            SOLID_QUEUE_IN_PUMA = "true";
            PROCESS_CHECKINS_INTERVAL_MINUTES = "60";
          };

          environmentFiles = [ "/run/secrets-lastsignal/lastsignal-env" ];

          volumes = [
            "/var/lib/containers/lastsignal/storage:/rails/storage:Z"
          ];
        };

        unitConfig = {
          After = [ "network-online.target" ];
          Description = "LastSignal dead man's switch container";
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "900";
          LogLevelMax = "warning";
        };
      };
    };
}
