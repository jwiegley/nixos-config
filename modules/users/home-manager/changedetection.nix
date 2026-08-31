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

          # Deployed by the sops `path=` override in
          # modules/containers/changedetection-quadlet.nix (was reached through a
          # tmpfiles `L+ .../changedetection -> /run/secrets/changedetection` symlink).
          environmentFiles = [ "/run/secrets-changedetection/api-key" ];

          volumes = [
            "/var/lib/changedetection:/datastore:rw"
          ];
        };

        unitConfig = {
          After = [
            "network-online.target"
            "sockpuppetbrowser.service"
          ];
          # Wants=, NOT Requires=. Requires propagates a STOP: when
          # sockpuppetbrowser.service is stopped, systemd stops this unit too --
          # and nothing ever starts it again, because Restart= covers unexpected
          # process exits and not deliberate stops, and WantedBy=default.target
          # only fires at target activation.
          #
          # That cost a real outage on 2026-08-27. Editing sockpuppetbrowser.service
          # (to add SuccessExitStatus=143) made home-manager restart it during
          # activation; this unit was stopped as a dependency casualty at 00:46:14,
          # the browser returned at 00:47:55, and changedetection stayed down until
          # 04:44 -- 3h58m, with ChangeDetectionAppDown, ChangeDetectionHTTPSProbeFailed
          # and WebServiceDown all firing. Any future edit to that unit would have
          # done the same thing.
          #
          # Wants= is the correct strength here because the browser is NOT a startup
          # dependency: the app reaches it per-fetch over
          # PLAYWRIGHT_DRIVER_URL=ws://10.0.2.2:3008, so it starts and serves its UI
          # with the browser absent, and only JS-rendered fetches fail until it is
          # back -- which they retry on schedule anyway. After= is kept, so ordering
          # at boot is unchanged; only the stop propagation is dropped.
          #
          # Upholds= (systemd 258 has it) was the alternative, keeping Requires= and
          # auto-restarting this unit. Rejected: it papers over the cascade rather
          # than preventing it, and it would make changedetection impossible to stop
          # for maintenance while the browser runs.
          Wants = [ "sockpuppetbrowser.service" ];
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

          # 143 is 128+15, i.e. the container exited on the SIGTERM that podman
          # sends to stop it -- a NORMAL shutdown. Without this, every ordinary
          # stop is recorded as `Failed with result 'exit-code'`, which showed up
          # in the journal on 08-21, 08-22, 08-24, 08-26 and 08-27, each time
          # alongside the nightly podman activity around 00:04. The unit is
          # healthy immediately afterwards (Restart=always brings it straight
          # back), so the entry is pure noise -- but it is noise in exactly the
          # "any service failures in the last 4 hours" check, so it costs a real
          # investigation every time someone looks.
          #
          # This does NOT hide a crash. A crashing browser dies on its own signal
          # (SIGSEGV -> 139, SIGABRT -> 134) or a nonzero application code, none of
          # which are 143, and liveness is covered by the port probe rather than by
          # the exit status.
          #
          # Deliberately NOT applied blanket-wide across containers. The
          # counter-example was nocobase (removed 2026-08-31), which exited 137
          # (128+9, SIGKILL) -- podman giving up after the stop timeout because
          # that image's PID 1 was a trap-less shell that never forwarded
          # SIGTERM. A 137 records a genuinely ungraceful shutdown and must stay
          # visible, so whitelisting an exit code is per-service and only ever
          # for a code that means a CLEAN stop.
          SuccessExitStatus = "143";
        };
      };
    };
}
