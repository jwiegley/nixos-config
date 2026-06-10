{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Custom queries for signals the built-in collectors do not expose cheaply.
  #
  # TXID / multixact WRAPAROUND (P1, database domain): age(datfrozenxid) is a
  # cluster-wide catalog read from pg_database, so it works from the exporter's
  # single `postgres` connection (NO --auto-discover-databases, which would
  # otherwise re-activate the default stat_user_tables collector across all 27
  # DBs and explode cardinality — ~1077 user tables × ~20 series each). This
  # emits one row per database (27 series). Wraparound is a silent-death risk:
  # at ~2.1B the cluster shuts down to protect itself; autovacuum_freeze_max_age
  # is 200M and the observed baseline is ~22M, so the 1e9/1.5e9 thresholds have
  # large headroom but fire well before the cliff.
  #
  # Uses the deprecated-but-functional --extend.query-path mechanism (the
  # classic queries.yaml schema) so the emitted metric names are fully under our
  # control and the alert exprs in alerts/database.yaml are guaranteed to match.
  #
  # pg_stat_statements_top (P2, database domain): bounded top-N-by-cumulative-
  # exec-time per-query latency. Reuses the SAME single `postgres`-DB master
  # connection — pg_stat_statements is cluster-wide so this row set spans all 26
  # DBs. The extension is loaded via shared_preload_libraries and CREATE'd by
  # the postgresql-pgstatstatements-setup oneshot in databases.nix; BOTH require
  # a planned PostgreSQL RESTART, so these metrics are ABSENT until that window
  # lands (the query errors harmlessly meanwhile, surfaced by
  # PostgreSQLExporterScrapeError via pg_scrape_collector_success).
  #
  # CARDINALITY: LIMIT 12 rows × 4 GAUGE columns = 48 series, inside the ≤50
  # budget. NEVER select the `query` text column — query text can embed literal
  # values (emails/tokens/search terms) and is a PII + cardinality risk. We emit
  # only queryid (opaque hash), datname, rolname as labels + numeric timers.
  # Operators look up the actual SQL ad-hoc:
  #   SELECT query FROM pg_stat_statements WHERE queryid = <id>;  (as postgres)
  pgCustomQueries = pkgs.writeText "postgres-custom-queries.yaml" ''
    pg_database_frozenxid:
      query: |
        SELECT datname,
               age(datfrozenxid)::float8       AS age,
               mxid_age(datminmxid)::float8    AS mxid_age
        FROM pg_database
        WHERE datallowconn
      master: true
      cache_seconds: 60
      metrics:
        - datname:
            usage: "LABEL"
            description: "Database name"
        - age:
            usage: "GAUGE"
            description: "Transaction-ID age of the database's datfrozenxid (transactions since last freeze; wraparound danger near 2.1e9)"
        - mxid_age:
            usage: "GAUGE"
            description: "Multixact-ID age of the database's datminmxid (multixact wraparound danger near 2.1e9)"

    pg_stat_statements_top:
      query: |
        SELECT s.queryid::text                   AS queryid,
               d.datname                          AS datname,
               r.rolname                          AS rolname,
               s.mean_exec_time                   AS mean_exec_time_ms,
               s.total_exec_time                  AS total_exec_time_ms,
               s.calls::float8                    AS calls,
               s.rows::float8                     AS rows
        FROM pg_stat_statements s
        JOIN pg_roles    r ON r.oid = s.userid
        JOIN pg_database d ON d.oid = s.dbid
        WHERE s.calls > 0
        ORDER BY s.total_exec_time DESC
        LIMIT 12
      master: true
      cache_seconds: 60
      metrics:
        - queryid:
            usage: "LABEL"
            description: "pg_stat_statements queryid (stable hash; NO query text)"
        - datname:
            usage: "LABEL"
            description: "Database name"
        - rolname:
            usage: "LABEL"
            description: "Executing role"
        - mean_exec_time_ms:
            usage: "GAUGE"
            description: "Mean execution time per call (ms)"
        - total_exec_time_ms:
            usage: "GAUGE"
            description: "Cumulative execution time since stats reset (ms)"
        - calls:
            usage: "GAUGE"
            description: "Total call count since stats reset"
        - rows:
            usage: "GAUGE"
            description: "Total rows returned/affected since stats reset"
  '';
in
{
  # PostgreSQL exporter
  services.prometheus.exporters.postgres = {
    enable = true;
    port = 9187;
    runAsLocalSuperUser = true;
    extraFlags = [
      # Custom cluster-wide wraparound query (see pgCustomQueries above).
      # Long-running-transaction visibility is covered without a new collector
      # by the default pg_stat_activity_max_tx_duration metric (verified live).
      "--extend.query-path=${pgCustomQueries}"
    ];
  };

  # Prometheus scrape configuration for PostgreSQL exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "postgres";
      static_configs = [
        {
          targets = [ "localhost:${toString config.services.prometheus.exporters.postgres.port}" ];
        }
      ];
    }
  ];

  # Service hardening and reliability
  systemd.services."prometheus-postgres-exporter" = {
    wants = [
      "network-online.target"
      "postgresql.service"
    ];
    after = [
      "network-online.target"
      "postgresql.service"
    ];
    startLimitIntervalSec = 0;
    startLimitBurst = 0;
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Firewall configuration
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    config.services.prometheus.exporters.postgres.port
  ];
}
