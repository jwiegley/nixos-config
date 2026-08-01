# Prometheus scrape job for stock-trader's /metrics endpoint.
#
# stock-trader exposes process-wide Counter metrics via prometheus_client
# at http://127.0.0.1:8234/metrics (mounted by src/web/app.py). The
# scrape job is intentionally local-only — stock-trader binds to
# loopback and is reverse-proxied by nginx for LAN traffic, so the
# scraper hits the loopback endpoint directly without going through
# nginx/TLS.
#
# Alert rules live in modules/monitoring/alerts/stock-trader.yaml; the
# original load-bearing one is StockTraderChatErrorRate, which fires when
# the chat WebSocket handler emits errors at a non-trivial rate. The
# motivating cause was an Anthropic→Responses adapter misorder bug in the
# LLM proxy that used to front this path (removed 2026-08-01)
# — the alert catches that bug regressing (or model prompt-adherence
# drifting and re-triggering it) without anyone having to type into
# the chat panel. Since stock-trader v0.2.0 (2026-06-09) this scrape job
# also backs the live-data freshness alerts StockTraderQuotesUnavailable and
# StockTraderStaleQuotesRejected. (It used to back StockTraderSchwabDataSourceDown
# as well; that rule was deleted 2026-07-29 with the Schwab source, plan item D3.)
{
  config,
  lib,
  ...
}:

{
  services.prometheus.scrapeConfigs = lib.mkIf config.services.stock-trader.enable [
    {
      job_name = "stock-trader";
      static_configs = [
        {
          targets = [ "127.0.0.1:8234" ];
          labels = {
            service = "stock-trader";
            instance = "vulcan";
          };
        }
      ];
      metrics_path = "/metrics";
      scrape_interval = "30s";
      scrape_timeout = "10s";
    }
  ];
}
