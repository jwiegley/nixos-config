{ ... }:

# Self-monitoring scrape jobs for the two TSDBs themselves.
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
#
# No new listening ports are introduced (9090/8428 already listen), so the port
# registry is unchanged.

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
  ];
}
