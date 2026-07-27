{ ... }:

# Self-monitoring scrape jobs for the monitoring stack's own /metrics endpoints:
# the two TSDBs, Alertmanager, and the cloudflared tunnel.
#
# Until 2026-06-09 neither Prometheus nor VictoriaMetrics was scraped, so every
# rule in prometheus-protection.yaml and victoriametrics-protection.yaml was dead
# (the metrics they reference — prometheus_tsdb_*, vm_* — never existed in the
# TSDB). These two jobs make the protection rules functional with no exporter:
# both processes already expose /metrics on their existing listen ports.
#
# - Prometheus  : http://localhost:9090/metrics  -> prometheus_tsdb_*,
#                 process_resident_memory_bytes{job="prometheus"}, etc.
# - VictoriaMetrics : http://127.0.0.1:8428/metrics -> vm_* (vm_allowed_memory_bytes,
#                 vm_available_memory_bytes, vm_slow_row_inserts_total, vm_rows, ...)
# - Alertmanager : http://localhost:9093/metrics -> alertmanager_* (notably
#                 alertmanager_notifications_failed_total per integration, which
#                 the meta-monitoring rules use to tell whether the iPhone/email/
#                 Discord delivery path itself is broken — the notification path
#                 must be monitored too, P0 #5).
#
# No new listening ports are introduced (9090/8428/9093 already listen), so the
# port registry is unchanged.

{
  services.prometheus.scrapeConfigs = [
    {
      job_name = "prometheus";
      static_configs = [
        { targets = [ "localhost:9090" ]; }
      ];
    }
    {
      job_name = "victoriametrics";
      static_configs = [
        { targets = [ "127.0.0.1:8428" ]; }
      ];
    }
    {
      job_name = "alertmanager";
      static_configs = [
        { targets = [ "localhost:9093" ]; }
      ];
    }
    # cloudflared public tunnel (data.newartisans.com et al.). The tunnel now
    # exposes its Prometheus metrics on 127.0.0.1:9301 via TUNNEL_METRICS (set in
    # modules/services/cloudflare-tunnels.nix). Scraping it yields the
    # cloudflared_* family — most importantly cloudflared_tunnel_ha_connections
    # (count of live edge/HA connections, normally ~4), which lets the
    # CloudflaredTunnel* alerts in alerts/dns.yaml catch a tunnel that is
    # "running" per systemd but has silently lost all its edge connections.
    # 9301 is loopback-only and already listening once the tunnel is up; no new
    # externally-exposed port. (Lives here rather than a standalone module to
    # follow the established self-scrape pattern for locally-exposed /metrics.)
    {
      job_name = "cloudflared";
      static_configs = [
        { targets = [ "127.0.0.1:9301" ]; }
      ];
    }
  ];
}
