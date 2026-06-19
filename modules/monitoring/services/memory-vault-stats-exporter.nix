{
  config,
  lib,
  pkgs,
  ...
}:

# Memory Vault has no native Prometheus metrics, so this oneshot collector
# queries the memory_vault database (as the postgres superuser over the local
# socket — peer auth, no password) and writes memory-store gauges to the
# node-exporter textfile directory. Scraped by the existing node-exporter
# textfile collector; visualized by the memory-vault Grafana dashboard.
#
# Emits: total/active chunk counts, space count, per-space active chunks, and
# 24h query volume / zero-result / mean-latency. memory_vault_stats_scrape_success
# is 0 before the app's first migration creates the schema.

let
  psql = "${config.services.postgresql.package}/bin/psql -d memory_vault -tAX";
  outFile = "/var/lib/prometheus-node-exporter-textfiles/memory-vault.prom";
in
{
  systemd.services.memory-vault-stats-exporter = {
    description = "Memory Vault DB stats -> node-exporter textfile";
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "postgres"; # peer auth -> postgres superuser, can read memory_vault
    };

    script = ''
      set -uo pipefail
      umask 022
      # Write to a temp file in the SAME dir then atomically rename, so a
      # concurrent node-exporter scrape never sees a half-written file. The temp
      # is cleaned up on any exit.
      TMP="${outFile}.tmp.$$"
      trap 'rm -f "$TMP"' EXIT
      publish() { ${pkgs.coreutils}/bin/chmod 0644 "$TMP"; ${pkgs.coreutils}/bin/mv -f "$TMP" "${outFile}"; }

      # Schema not present yet (pre first-migration): report scrape failure, bail.
      if ! ${psql} -c "SELECT to_regclass('public.chunks')" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q '^chunks$'; then
        printf 'memory_vault_stats_scrape_success 0\n' > "$TMP"
        publish
        exit 0
      fi

      # `var=$(...) || failed=1`: the assignment's exit status IS the query's, so
      # a schema-drift error flips `failed` in THIS shell (not a lost subshell),
      # and scrape_success drops to 0 instead of silently reporting wrong zeros.
      failed=0
      total=$(${psql} -c "SELECT count(*) FROM chunks" 2>/dev/null) || failed=1
      active=$(${psql} -c "SELECT count(*) FROM chunks WHERE importance>0 AND (metadata->>'forgotten')::boolean IS NOT TRUE" 2>/dev/null) || failed=1
      spaces=$(${psql} -c "SELECT count(*) FROM memory_spaces" 2>/dev/null) || failed=1
      q24=$(${psql} -c "SELECT count(*) FROM query_log WHERE created_at >= now() - interval '24 hours'" 2>/dev/null) || failed=1
      qzero=$(${psql} -c "SELECT count(*) FROM query_log WHERE created_at >= now() - interval '24 hours' AND result_count=0" 2>/dev/null) || failed=1
      qlat=$(${psql} -c "SELECT coalesce(round(avg(latency_ms)::numeric,1),0) FROM query_log WHERE created_at >= now() - interval '24 hours'" 2>/dev/null) || failed=1

      {
        echo '# HELP memory_vault_stats_scrape_success 1 if all memory_vault DB stat queries succeeded.'
        echo '# TYPE memory_vault_stats_scrape_success gauge'
        echo "memory_vault_stats_scrape_success $([ "$failed" -eq 0 ] && echo 1 || echo 0)"
        echo '# HELP memory_vault_chunks_total Total chunks (including forgotten/soft-deleted).'
        echo '# TYPE memory_vault_chunks_total gauge'
        echo "memory_vault_chunks_total ''${total:-0}"
        echo '# HELP memory_vault_active_chunks_total Active (non-forgotten, importance>0) chunks.'
        echo '# TYPE memory_vault_active_chunks_total gauge'
        echo "memory_vault_active_chunks_total ''${active:-0}"
        echo '# HELP memory_vault_spaces_total Number of memory spaces.'
        echo '# TYPE memory_vault_spaces_total gauge'
        echo "memory_vault_spaces_total ''${spaces:-0}"
        echo '# HELP memory_vault_queries_24h Hybrid-search queries logged in the last 24h.'
        echo '# TYPE memory_vault_queries_24h gauge'
        echo "memory_vault_queries_24h ''${q24:-0}"
        echo '# HELP memory_vault_zero_result_queries_24h Queries in last 24h returning no results.'
        echo '# TYPE memory_vault_zero_result_queries_24h gauge'
        echo "memory_vault_zero_result_queries_24h ''${qzero:-0}"
        echo '# HELP memory_vault_query_avg_latency_ms Mean hybrid-search latency (ms) over last 24h.'
        echo '# TYPE memory_vault_query_avg_latency_ms gauge'
        echo "memory_vault_query_avg_latency_ms ''${qlat:-0}"
        echo '# HELP memory_vault_space_active_chunks Active chunks per memory space.'
        echo '# TYPE memory_vault_space_active_chunks gauge'
      } > "$TMP"

      # Per-space active chunks (psql -A → pipe-separated rows).
      ${psql} -c "SELECT ms.name, count(c.id) FILTER (WHERE c.importance>0 AND (c.metadata->>'forgotten')::boolean IS NOT TRUE) FROM memory_spaces ms LEFT JOIN chunks c ON c.space_id=ms.id GROUP BY ms.name ORDER BY ms.name" 2>/dev/null \
        | while IFS='|' read -r name cnt; do
            [ -z "$name" ] && continue
            esc=$(printf '%s' "$name" | ${pkgs.gnused}/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "memory_vault_space_active_chunks{space=\"$esc\"} ''${cnt:-0}" >> "$TMP"
          done

      publish
    '';
  };

  systemd.timers.memory-vault-stats-exporter = {
    description = "Periodic Memory Vault DB stats collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
    };
  };
}
