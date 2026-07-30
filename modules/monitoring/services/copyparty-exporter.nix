{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Copyparty Prometheus metrics monitoring
  #
  # Scrapes copyparty's `stats` endpoint (/.cpr/metrics) with basic auth, going
  # DIRECT to the container address 10.233.2.2:3923 — it does NOT traverse the
  # socket-activated copyparty-http proxy on 127.0.0.1:13923 (see
  # modules/containers/copyparty-container.nix). The old header comment here
  # claiming "metrics exposed at http://localhost:13923/.cpr/metrics (via
  # container port forward)" described a path this job has never used.
  #
  # ── VERIFIED ROOT CAUSE of the 2026-07-20 and 2026-07-23 scrape outages ──
  #
  # Both outages were copyparty banning the HOST, via its own --ban-403.
  #
  #   up{job="copyparty"} 1->0  2026-07-20 19:36:30, recovered 07-21 12:36:30  (17.0h)
  #   up{job="copyparty"} 1->0  2026-07-23 00:02:30, recovered 07-23 22:42:00  (22.7h)
  #
  # Chain of events, each link measured rather than inferred:
  #
  #  1. networkd gives the host end of the veth a link-local address in ADDITION
  #     to the /32 pair (40-ve-copyparty sets LinkLocalAddressing = "yes"):
  #     ve-copyparty carries both 169.254.x.y/16 and 10.233.2.1/32. Because
  #     10.233.2.1 is a /32 (not on-link with the container) while the
  #     link-local is a real on-link /16 on the same device, the kernel picks
  #     the LINK-LOCAL as the source address:
  #         `ip route get 10.233.2.2` -> `dev ve-copyparty src 169.254.x.y`
  #     So every host->container HTTP connection — this Prometheus scrape, the
  #     copyparty-http socket proxy, and therefore all public traffic arriving
  #     through nginx/cloudflared — reaches copyparty from ONE shared source IP.
  #  2. At the time, copyparty did not trust x-forwarded-for from that address
  #     and warned about it on literally every proxied request, so it attributed
  #     public traffic to the shared host IP instead of the real client.
  #  3. An internet scanner probed /.env, /sendgrid.env, /twilio.env, /api/.env
  #     and /phpinfo through the public tunnel. copyparty's --ban-403 default is
  #     "9,2,1440": 9 x 403 within 2 minutes => ban for 1440 minutes. The 9th
  #     403 tripped it and the container journal recorded
  #         `CRIT: client banned: 403s`  then  `BTW: banned for 86400 sec`
  #     against the shared host address — i.e. copyparty banned vulcan itself.
  #  4. A banned client gets `terse_reply(b"thank you for playing", 403)`
  #     (copyparty httpcli.py is_banned), so the scrape received an immediate
  #     403. TSDB signature during the ban: scrape_samples_scraped == 0 and
  #     scrape_duration_seconds ~= 1.5ms (healthy baseline 5.8ms).
  #  5. Each outage ended when the container restarted, dropping the in-memory
  #     ban table well before the 24h expiry.
  #
  # Hypotheses this REFUTES, with the evidence:
  #  * "10s scrape_timeout on a cold socket-activated path": no. The scrape does
  #    not use the socket-activated proxy at all, and the failing scrapes took
  #    ~1.5ms — a fast 403, not a timeout. 700x headroom on the timeout.
  #  * "the container never restarted": it did, twice, exactly at the two
  #    recovery instants. The restarts are invisible in the HOST unit journal
  #    for container@copyparty.service but plain in the container's OWN journal:
  #    `journalctl -M copyparty --list-boots` shows boots beginning
  #    2026-07-21 12:36:29 and 2026-07-23 22:41:17.
  #  * "the evidence is genuinely absent": it is not. It is in
  #    `journalctl -M copyparty` (the ban lines above) and in the TSDB
  #    (probe_http_status_code for the public edge read 403 for the whole
  #    22.7h window). Nobody had looked in either place.
  #
  # The upstream fix — trusting x-forwarded-for so bans hit the real client —
  # landed separately in modules/services/copyparty.nix ("xff-src: lan", commit
  # 4e35dadd) and is live: zero untrusted-xff warnings in the current container
  # boot, and copyparty's `lan` shorthand does expand to include 169.254.0.0/16
  # (util.py L2894-L2904), so the host address is now a trusted proxy source.
  #
  # This module's job is the part that fix does NOT cover: making a recurrence
  # DIAGNOSABLE. The scrape still identifies to copyparty as the shared host
  # address whenever a request carries no x-forwarded-for, so it can still be
  # collaterally banned; and copyparty's own ban counters cannot report it (see
  # the copyparty_origin probe below).

  # Load copyparty password credential into Prometheus service
  systemd.services.prometheus = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];

    # Use systemd LoadCredential to make password available
    # Password will be available at $CREDENTIALS_DIRECTORY/copyparty-password
    serviceConfig = {
      LoadCredential = "copyparty-password:${config.sops.secrets."copyparty/johnw-password".path}";
    };
  };

  # Prometheus scrape configuration for Copyparty metrics.
  #
  # Scrapes the container address directly. (The original comment here said this
  # was "since systemd-nspawn port forwarding is unreliable"; that claim is
  # undocumented and untested — the copyparty-http socket proxy is up and the
  # direct path measures 1.5-14ms, so there is no evidence either way. Left as
  # direct because it is the shorter path and it is what the 2026-07 incident
  # analysis above is calibrated against.)
  services.prometheus.scrapeConfigs = [
    {
      job_name = "copyparty";
      static_configs = [
        {
          targets = [ "10.233.2.2:3923" ]; # Container IP:port
          labels = {
            service = "copyparty";
            instance = "vulcan";
          };
        }
      ];
      metrics_path = "/.cpr/metrics";
      scrape_interval = "30s";

      # 10s is ~700x the measured scrape duration (5.8ms mean / 14ms max over a
      # healthy day). It is NOT implicated in the 2026-07 outages: those scrapes
      # failed in ~1.5ms with an immediate 403. Do not "fix" this by raising it.
      scrape_timeout = "10s";

      # Basic authentication using copyparty credentials
      basic_auth = {
        username = "johnw";
        password_file = "/run/credentials/prometheus.service/copyparty-password";
      };
    }

    # ── Ban/liveness discriminator for the copyparty origin ──────────────────
    #
    # WHY THIS EXISTS. When the `copyparty` job above fails, Prometheus records
    # up=0 and keeps the reason (the HTTP status, the connection error) only in
    # the target's in-memory lastError, which is overwritten by the next
    # successful scrape. Prometheus does not log scrape failures at its default
    # log level either, so after the fact there is NOTHING that distinguishes
    # "copyparty banned us and answered 403" from "the container is dead" from
    # "credentials are wrong". That is exactly why the 07-20 and 07-23 outages
    # could not be root-caused from the monitoring data.
    #
    # A blackbox probe fixes that, because probe_http_status_code is a real
    # persisted series:
    #     200 -> healthy
    #     403 -> copyparty answered and refused us == BANNED (or auth-gated)
    #       0 -> no HTTP response at all == container/service down or unreachable
    # Combined with up{job="copyparty"} this is unambiguous, and it is retained
    # for as long as any other metric.
    #
    # It probes the container's own address, so it shares the source IP (and
    # therefore the ban identity) with the metrics scrape above — a ban that
    # blinds the scrape also shows up here, which is the whole point. The
    # existing public-edge probe cannot substitute: it sits behind
    # nginx+cloudflared, so a 403 there is not attributable to copyparty.
    #
    # WHY IT PROBES "/" AND NOT THE METRICS PATH — this is a trap, not a
    # preference. An anonymous GET of /.cpr/metrics returns 403. copyparty's
    # --ban-403 default is 9 x 403 in 2 minutes; at a 30s interval an
    # unauthenticated probe of an auth-gated path would trip that in 4.5
    # minutes and inflict the exact 24h outage this probe is meant to detect.
    # Anonymous GET / returns 200 (verified live: probe_http_status_code 200,
    # probe_success 1, 1.9ms) because a volume in modules/services/copyparty.nix
    # grants anonymous read, so this probe generates no 403s and cannot
    # contribute to a ban.
    #
    # MAINTENANCE HAZARD: that 200 is a precondition, not an invariant. If
    # anonymous read at `/` is ever revoked, this probe starts emitting a 403
    # every 30s and will self-inflict a 24h ban within 4.5 minutes. If you
    # change the volume ACLs, re-check with
    #   curl -s -o /dev/null -w '%{http_code}\n' http://10.233.2.2:3923/
    # and if it is no longer 200, remove this job rather than leaving it armed.
    #
    # WHY THE JOB NAME DELIBERATELY OMITS THE "blackbox_" PREFIX used elsewhere:
    # two generic rules key on it and would turn one incident into three pages.
    #   HostUnreachable  probe_success{...,job=~"blackbox_.*"} == 0
    #   WebServiceDown   probe_success{job!="blackbox_https_public",job=~"blackbox_http.*"} == 0
    # CopypartyDown (up{job="copyparty"} == 0, for 5m) already provides the
    # acute page, so this series is intentionally a DIAGNOSTIC, not a second
    # pager. It is still swept up by ProbeTargetChronicallyFailing, which has no
    # job filter and only fires on a weekly availability shortfall — the
    # appropriate chronic-outage backstop, and the rule whose own comments in
    # alerts/network.yaml were written from copyparty's 86.51% week.
    {
      job_name = "copyparty_origin";
      metrics_path = "/probe";
      params = {
        module = [ "http_2xx" ];
      };
      static_configs = [
        {
          targets = [ "http://10.233.2.2:3923/" ];
          labels = {
            service = "copyparty";
          };
        }
      ];
      scrape_interval = "30s";
      scrape_timeout = "10s";
      relabel_configs = [
        {
          source_labels = [ "__address__" ];
          target_label = "__param_target";
        }
        {
          source_labels = [ "__param_target" ];
          target_label = "instance";
        }
        {
          target_label = "__address__";
          replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
        }
        {
          target_label = "probe_type";
          replacement = "copyparty_origin";
        }
      ];
    }
  ];

  # Documentation
  environment.etc."copyparty/metrics-monitoring.md" = {
    text = ''
      # Copyparty Prometheus Metrics Monitoring

      ## Overview
      Copyparty exposes Prometheus metrics via its `stats` endpoint at
      `/.cpr/metrics`. Prometheus scrapes it DIRECTLY at the container address
      `http://10.233.2.2:3923/.cpr/metrics` with basic auth — it does not use the
      socket-activated `copyparty-http` proxy on `127.0.0.1:13923`. Both paths
      exist; only the direct one is scraped.

      Metric names are prefixed `cpp_` (e.g. `cpp_http_conns`, `cpp_total_bans`,
      `cpp_uptime_seconds`, `cpp_idle_vols`, `cpp_busy_vols`,
      `cpp_sus_reqs_total`). There are no `copyparty_*` metrics.

      ## Checking Metrics
      ```bash
      # Metrics endpoint (needs auth; anonymous GET returns 403 -- see the ban
      # warning below before you loop this)
      curl -u johnw:PASS http://10.233.2.2:3923/.cpr/metrics

      # Scrape status of both copyparty jobs
      curl -s http://localhost:9090/api/v1/targets \
        | jq '.data.activeTargets[] | select(.labels.job|test("copyparty"))
              | {job:.labels.job, health, lastError, lastScrapeDuration}'
      ```

      ## Accessing Copyparty
      - **Web UI**: https://data.newartisans.com (cloudflared -> nginx -> container)
      - **Origin**: http://10.233.2.2:3923/ (anonymous GET / returns 200)
      - **Local proxy**: 127.0.0.1:13923 (systemd-socket-proxyd, not scraped)

      ## FIRST THING TO CHECK when the copyparty scrape goes down

      Copyparty bans clients by source IP, and every host->container connection
      arrives from ONE shared link-local source address (the kernel picks it over
      the 10.233.2.1/32 — confirm with `ip route get 10.233.2.2`). So copyparty
      can ban vulcan itself, which takes out the metrics scrape AND every real
      user behind the reverse proxy at the same time. This happened twice:
      17.0h from 2026-07-20 19:36 and 22.7h from 2026-07-23 00:02, both from an
      internet scanner probing `/.env`-style paths through the public tunnel.
      The ban is `--ban-403` default `9,2,1440` = 9 x 403 in 2 min -> 24 hours.

      ```bash
      # 1. Was it a ban?  THE evidence, and it is in the CONTAINER's journal --
      #    the host unit journal for container@copyparty.service shows nothing.
      sudo journalctl -M copyparty --since "-2d" \
        | grep -E "client banned|banned for|client unbanned"

      # 2. Ban vs dead vs auth, straight from the TSDB (retained, unlike
      #    Prometheus's in-memory lastError which the next good scrape erases):
      #      403 -> banned or auth-refused, service is ALIVE
      #        0 -> no HTTP response, service is DOWN
      curl -s 'http://localhost:9090/api/v1/query?query=probe_http_status_code%7Bjob%3D%22copyparty_origin%22%7D' | jq '.data.result'

      # 3. Timeout or instant refusal?  ~1.5ms = instant 403 (a ban).
      #    A real timeout would sit at the 10s scrape_timeout.
      curl -s 'http://localhost:9090/api/v1/query?query=scrape_duration_seconds%7Bjob%3D%22copyparty%22%7D' | jq '.data.result'

      # 4. Did the container restart?  Also only visible from inside.
      sudo journalctl -M copyparty --list-boots | tail -5
      ```

      **Clearing a ban:** the ban table is in-memory only, so restarting the
      copyparty service inside the container drops it immediately —
      `sudo machinectl shell copyparty /run/current-system/sw/bin/systemctl restart copyparty`.
      That is what accidentally ended both 2026-07 outages. Prefer fixing the
      attribution (see `xff-src` in `modules/services/copyparty.nix`) over
      restarting, or the ban simply returns on the next scanner sweep.

      **Do not** point a monitoring probe at an auth-gated copyparty path
      anonymously. Each anonymous hit is a 403; at a 30s interval you trip
      `--ban-403` in 4.5 minutes and cause a 24-hour outage of both metrics and
      the public site. The `copyparty_origin` probe deliberately requests `/`,
      which returns 200.

      ## Known blind spot
      `cpp_total_bans` (and the `CopypartyFrequentBans` /
      `CopypartyAuthFailures` alerts built on it) cannot report a ban that hits
      the scraper itself: the ban blocks the very scrape that would carry the
      counter. Verified — `max_over_time(cpp_total_bans[30d])` is 0 across a
      window containing two real 24-hour bans. Use `probe_http_status_code
      {job="copyparty_origin"}` and the container journal instead.

      ## Other Troubleshooting
      - **Service state inside the container**:
        ```bash
        sudo machinectl shell copyparty /run/current-system/sw/bin/systemctl status copyparty
        ```
      - **Authentication errors**: verify the credential reached Prometheus
        (metadata only — do not cat it):
        ```bash
        systemctl show prometheus -p LoadCredential
        ls -la /run/credentials/prometheus.service/
        ```
      - **Grafana**: https://grafana.vulcan.lan — Copyparty dashboard. Query the
        `cpp_*` names above; the `copyparty_*` names in the old version of this
        document never existed.

      ## Related Files
      - Module: /etc/nixos/modules/monitoring/services/copyparty-exporter.nix
      - Service config: /etc/nixos/modules/services/copyparty.nix
      - Container config: /etc/nixos/modules/containers/copyparty-container.nix
      - Prometheus config: /etc/nixos/modules/monitoring/services/prometheus-server.nix
      - Dashboard: /etc/nixos/modules/monitoring/dashboards/copyparty.json

      ## Service Management
      ```bash
      # Check service status (in container)
      sudo machinectl shell copyparty /run/current-system/sw/bin/systemctl status copyparty

      # Restart service (in container)
      sudo machinectl shell copyparty /run/current-system/sw/bin/systemctl restart copyparty

      # View logs (in container)
      sudo machinectl shell copyparty /run/current-system/sw/bin/journalctl -u copyparty -f

      # Check Prometheus scraping
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="copyparty")'
      ```
    '';
    mode = "0644";
  };
}
