{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  # Import helper functions
  common = import ../lib/common.nix { inherit secrets; };
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # Set up PostgreSQL passwords for database users
    (mkPostgresUserSetup {
      user = "budgetboard";
      database = "budgetboard";
      secretPath = config.sops.secrets."budgetboard/database-password".path;
      dependentService = "podman-budget-board-server.service";
    })
    # NocoBase (evaluation, restored 2026-08-15). Gated on services.nocobase.enable.
    #
    # `imports` is static, so this entry is always present and instead wraps its
    # own config in mkIf. secretPath is the literal /run/secrets path rather than
    # config.sops.secrets."nocobase-db-password".path on purpose: that attribute
    # only exists when the secret is declared, which is itself gated, so reading
    # it here would force evaluation and fail while NocoBase is off. The literal
    # is the sops default path for a secret with no `path=` override, which is
    # exactly how modules/containers/nocobase-quadlet.nix declares it.
    (
      { lib, ... }:
      lib.mkIf config.services.nocobase.enable (mkPostgresUserSetup {
        user = "nocobase";
        database = "nocobase";
        secretPath = "/run/secrets/nocobase-db-password";
        dependentService = "podman-nocobase.service";
      })
    )
    # Grist (2026-08-19). Gated on services.grist.enable, and structured exactly
    # like the NocoBase entry above for the same reason: `imports` is static, so
    # the entry is always present and wraps its own config in mkIf, and
    # secretPath is the LITERAL /run/secrets path rather than the
    # config.sops.secrets attribute, which only exists while the gate is on.
    #
    # Grist keeps only its HOME database here -- orgs, workspaces, users, ACLs.
    # The spreadsheets themselves are SQLite files under /var/lib/grist, so a
    # PostgreSQL backup alone does NOT capture Grist documents.
    (
      { lib, ... }:
      lib.mkIf config.services.grist.enable (mkPostgresUserSetup {
        user = "grist";
        database = "grist";
        secretPath = "/run/secrets/grist-db-password";
        dependentService = "podman-grist.service";
      })
    )
    (mkPostgresUserSetup {
      user = "rspamd";
      database = "rspamd";
      secretPath = config.sops.secrets."rspamd-db-password".path;
      dependentService = "rspamd.service";
    })
    (mkPostgresUserSetup {
      user = "mailarchiver";
      database = "mailarchiver";
      secretPath = config.sops.secrets."mailarchiver-db-password".path;
      dependentService = "podman-mailarchiver.service";
    })
    (mkPostgresUserSetup {
      user = "openproject";
      database = "openproject";
      secretPath = config.sops.secrets."openproject-db-password".path;
      dependentService = "podman-openproject.service";
    })
    (mkPostgresUserSetup {
      user = "speedtest_tracker";
      database = "speedtest_tracker";
      secretPath = config.sops.secrets."speedtest-tracker-db-password".path;
    })
    (mkPostgresUserSetup {
      user = "openclaw";
      database = "org";
      secretPath = config.sops.secrets."openclaw/org-db-password".path;
    })
  ];

  services = {
    postgresql = {
      enable = true;
      enableTCPIP = true;

      package = pkgs.postgresql_17.withPackages (p: [ p.pgvector ]);

      settings = {
        port = 5432;

        # Memory settings - system has 62GB RAM; larger shared_buffers reduces disk reads.
        #
        # Raised 2GB -> 8GB on 2026-08-16 for nixos-06u. Measured cause: the
        # cluster's steady-state cache-hit ratio is ~99.5%, but `hass` runs at 63%
        # reading ~208 blocks/s from disk during active periods, dragging the
        # (then cluster-wide) alert under its 0.85 threshold for hours at a time.
        # hass is 2.6GB with a 1.2GB `states` table and 3.6M live tuples, so its
        # hot set alone is a large fraction of a 2GB buffer pool shared with ~26
        # other databases totalling ~17GB. 8GB lets the working set actually sit
        # in cache. Headroom is ample: 62GB total with ~27GB in use and ~32GB
        # already in page cache, so this reallocates memory the kernel was
        # caching anyway, into a pool PostgreSQL can manage directly.
        #
        # !!! CHANGING THIS RESTARTS POSTGRESQL ON THE NEXT SWITCH. Measured on
        # 2026-08-16, not assumed: this edit alone caused switch-to-configuration
        # to restart postgresql.service (new MainPID, ActiveEnterTimestamp moved),
        # after which `SHOW shared_buffers` read 8GB and pg_settings reported 0
        # rows with pending_restart. So the value went live immediately, and the
        # ~26 databases plus ~33 reverse-dependent units were bounced as part of
        # a routine switch.
        #
        # That contradicts the shared_preload_libraries note below, which says a
        # switch only RELOADS. Both observations are real and they are not in
        # conflict: a reload suffices for reloadable settings, while a change to a
        # postmaster-level setting like shared_buffers makes NixOS restart the
        # unit. Treat any edit to THIS setting as a planned-window action, and do
        # not infer from the note below that it will be applied gently.
        shared_buffers = "8GB";
        # Planner hint only -- allocates nothing, so it takes effect on reload
        # rather than needing the restart above. 24GB reflects what is genuinely
        # available to PostgreSQL between its own buffers and the kernel page
        # cache on this host; the old 4GB understated it enough to bias the
        # planner toward sequential scans.
        effective_cache_size = "24GB";
        work_mem = "32MB"; # Per-sort/hash, 200 connections * ~3 = ~19GB worst case

        # Connection settings
        max_connections = 200; # Increased from default 100 to handle bulk operations

        # Network Security - Listen on all interfaces (auth rules control access)
        listen_addresses = lib.mkForce "*";
        ssl = true;
        ssl_cert_file = "/var/lib/postgresql/certs/server.crt";
        ssl_key_file = "/var/lib/postgresql/certs/server.key";
        ssl_ca_file = "/var/lib/postgresql/certs/root_ca.crt";
        ssl_ciphers = "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4:!3DES";
        ssl_prefer_server_ciphers = true;
        ssl_min_protocol_version = "TLSv1.2";
        ssl_max_protocol_version = "TLSv1.3";

        # Authentication settings
        password_encryption = "scram-sha-256";

        # Session timeouts
        # Automatically terminate connections that are idle in a transaction for too long
        # This prevents locks from being held indefinitely by abandoned transactions
        idle_in_transaction_session_timeout = "10min"; # 10 minutes

        # Logging configuration for troubleshooting
        # Log slow queries (longer than 1 second)
        log_min_duration_statement = 1000; # milliseconds

        # Suppress parameter-value dumps on slow-query LOG lines.
        # Keeps timing and SQL text; drops the DETAIL Parameters: block
        # that floods the error stream with e.g. large email bodies from
        # mailarchiver INSERTs. Errors already elide parameters via
        # log_parameter_max_length_on_error = 0 (default).
        log_parameter_max_length = 0;

        # Log lock waits that take longer than deadlock_timeout
        log_lock_waits = true;
        deadlock_timeout = "1s"; # How long to wait before checking for deadlock

        # Log checkpoints (helps identify I/O bottlenecks)
        log_checkpoints = true;

        # Log autovacuum activity (only log runs taking longer than 10 seconds)
        log_autovacuum_min_duration = 10000; # Log autovacuum runs > 10s to reduce noise

        # Include more context in logs
        # %m timestamp, %p pid, then %q (drop the rest for non-session
        # processes) followed by %u@%d = user@database. NOTE: %q is a
        # stop-marker, not the application name — that would be %a.
        log_line_prefix = "%m [%p] %q%u@%d ";

        # pg_stat_statements: per-query aggregate latency telemetry.
        #
        # RESTART BLAST RADIUS: shared_preload_libraries is NOT reloadable —
        # changing it requires a full `systemctl restart postgresql.service`,
        # which bounces ~26 user databases and the 33 reverse-dependent units
        # (immich-server, immich-machine-learning, gitea, home-assistant,
        # budget-board-server, nagios, pgadmin, + ~14
        # postgresql-*-setup oneshots). A `nixos-rebuild switch` only RELOADS
        # PostgreSQL on a settings change — it does NOT restart it — so the
        # library does not actually load until an EXPLICIT restart. Fold that
        # restart into a planned maintenance window; do NOT ride a routine
        # unattended switch. The StartLimitBurst=30/RestartSec hardening below
        # + the exporter's Restart=always mean the dependents self-recover.
        # STATUS: that restart has already happened — as of 2026-07-27
        # `SHOW shared_preload_libraries` reads "vchord.so,pg_stat_statements".
        # The warning above still governs any FUTURE change to this setting.
        #
        # The immich nixpkgs module owns shared_preload_libraries as a plain
        # list assignment ([ "vchord.so" ]); use lib.mkAfter so we APPEND
        # pg_stat_statements rather than clobber vchord (vector index for
        # immich CLIP search). Post-restart SHOW must read
        # "vchord.so, pg_stat_statements".
        shared_preload_libraries = lib.mkAfter [ "pg_stat_statements" ];

        # Bound the in-memory statement ring (~16 MB shared mem at 1k entries —
        # noise on a 62 GB box). track=top records only top-level statements
        # (excludes PL/pgSQL-internal SQL, keeps memory + queryid set bounded).
        # save=off does NOT persist stats across restarts (no /var growth, no
        # stale baselines). queryid is auto-computed because compute_query_id
        # is already 'auto' (verified live) — if that is ever set to 'off',
        # queryid collapses to 0 and the exporter join folds all statements
        # into one row, so leave compute_query_id alone.
        "pg_stat_statements.max" = 1000;
        "pg_stat_statements.track" = "top";
        "pg_stat_statements.save" = false;
      };

      ensureDatabases = [
        "open_webui"
        "wallabag"
      ]
      ++ lib.optional config.services.nocobase.enable "nocobase"
      # Grist's HOME database only -- orgs, workspaces, users, ACLs. The
      # spreadsheet documents are SQLite files under /var/lib/grist and are not
      # in PostgreSQL, so this database being intact does not mean the documents
      # are.
      ++ lib.optional config.services.grist.enable "grist"
      ++ [
        "budgetboard"
        "gitea"
        "mailarchiver"
        "openproject"
        "speedtest_tracker"
        "nodered_events"
        "flume-data"
      ];
      ensureUsers = [
        { name = "postgres"; }
        { name = "johnw"; }
        { name = "wallabag"; }
      ]
      ++ lib.optional config.services.nocobase.enable {
        name = "nocobase";
        ensureDBOwnership = true;
      }
      # Creates the ROLE. postgresql-grist-setup only sets its password, and
      # fails outright with `role "grist" does not exist` if this is missing --
      # which is exactly what happened on the first attempt to enable Grist,
      # because the setup service was added without its counterpart here.
      # ensureDBOwnership requires the database name to equal the user name;
      # both are "grist".
      ++ lib.optional config.services.grist.enable {
        name = "grist";
        ensureDBOwnership = true;
      }
      ++ [
        {
          name = "budgetboard";
          ensureDBOwnership = true;
        }
        {
          name = "mailarchiver";
          ensureDBOwnership = true;
        }
        {
          name = "openproject";
          ensureDBOwnership = true;
        }
        {
          name = "open_webui";
          ensureDBOwnership = true;
        }
        {
          name = "speedtest_tracker";
          ensureDBOwnership = true;
        }
        {
          name = "openclaw";
          # No ensureDBOwnership — openclaw gets read-only access to org, not ownership
        }
        { name = "node-red"; }
        { name = "grafana"; }
        {
          name = "flume-data";
          ensureDBOwnership = true;
        }
      ];

      authentication = lib.mkOverride 10 ''
        # TYPE  DATABASE  USER  ADDRESS         METHOD  OPTIONS

        # Unix socket connections - require password for non-postgres users
        local   all       postgres                peer
        # Immich uses peer auth (NixOS native module)
        local   immich    immich                  peer
        local   nodered_events  node-red                peer
        local   nodered_events  grafana                 peer
        local   flume-data   flume-data          peer
        local   flume-data   grafana                 peer
        local   flume-data   johnw                   peer
        local   flume-data   hass                    peer
        # flume-data needs read-only access to HA's states table to derive
        # irrigation sessions from B-Hyve valve.* entities (used by the v2
        # classifier in flume_data/classify_v2.py to suppress false-positive
        # pool autofills during scheduled watering windows).
        local   hass         flume-data          peer
        local   all       all                     scram-sha-256

        # Localhost connections - require password
        host    all       postgres   127.0.0.1/32    scram-sha-256
        host    all       all        127.0.0.1/32    scram-sha-256
        host    all       all        ::1/128         scram-sha-256

        # Podman network - require password (containers should use passwords)
        host    all       all        10.88.0.0/16    scram-sha-256

        # OpenClaw microVM bridge network — Sherlock queries org database

        # Hermes microVM bridge network — org-db MCP server (org_sql) queries
        # the org database as the same read-only `openclaw` role. Hermes reaches
        # PostgreSQL via its own two-stage DNAT, so connections arrive sourced
        # from the Hermes VM IP 10.99.1.2 (subnet 10.99.1.0/30).
        host    org       openclaw   10.99.1.0/30    scram-sha-256

        # Local networks - SSL required with client certificate verification
        hostssl all       postgres   192.168.0.0/16  scram-sha-256
        hostssl all       all        192.168.0.0/16  scram-sha-256

        # Nebula network - SSL required
        hostssl all       all        10.6.0.0/24     scram-sha-256

        # Reject all other connections
        host    all       all        0.0.0.0/0       reject
        host    all       all        ::/0            reject
      '';
    };
  };

  services.nginx.virtualHosts."postgres.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/postgres.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/postgres.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:5050/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header X-Script-Name "";
        proxy_set_header Host $host;
        proxy_redirect off;
      '';
    };
  };

  # Optimize mailarchiver database with performance indexes
  # Fixes PostgreSQLSlowQueries alert caused by sequential scans on ArchivedEmails
  systemd.services.postgresql-mailarchiver-optimize = {
    description = "Create performance indexes for mailarchiver database";
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for PostgreSQL to be ready
      until ${config.services.postgresql.package}/bin/psql -d mailarchiver -c "SELECT 1" 2>/dev/null; do
        sleep 1
      done

      # Force the planner away from "ORDER BY SentDate DESC LIMIT n" + per-row
      # to_tsvector() filter scans, which bypass the full-text GIN index below.
      # For terms the planner estimates as common it walks IX_ArchivedEmails_SentDate
      # backward and re-tokenizes every (detoasted) Body as a filter — ~22 s when
      # matches are sparse/old, vs <1 ms via the GIN index. Disabling plain index
      # scans for this role makes search use the GIN bitmap scan reliably; the
      # sync/dedup MailAccountId+MessageId lookups stay indexed via bitmap scans.
      # Role-scoped and reversible: ALTER ROLE mailarchiver RESET enable_indexscan;
      ${config.services.postgresql.package}/bin/psql -c \
        'ALTER ROLE mailarchiver SET enable_indexscan = off;'

      # Check if the mail_archiver schema and ArchivedEmails table exist
      # (they are created by the application on first run via EF Core migrations)
      if ${config.services.postgresql.package}/bin/psql -d mailarchiver -tAc \
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'mail_archiver' AND table_name = 'ArchivedEmails'" | grep -q 1; then

        # Create composite index for MessageId + MailAccountId lookups
        # The application frequently queries by these columns to check for duplicate emails
        # Without this index, queries do expensive sequential scans on 200k+ rows
        ${config.services.postgresql.package}/bin/psql -d mailarchiver -c \
          'CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_archivedemails_mailaccountid_messageid ON mail_archiver."ArchivedEmails" ("MailAccountId", "MessageId");'

        # Full-text search GIN index backing the application's optimized search
        # query (to_tsvector('simple', Subject||Body||From||To||Cc||Bcc) @@ to_tsquery).
        # The expression MUST match the app's SearchEmailsOptimizedAsync query
        # verbatim for the planner to use it. The app does NOT create this index
        # itself, so without it search falls back to full-table tsvector scans.
        # Written via writeText + psql -f so the empty-string and quoted
        # identifier literals in the expression do not collide with quoting.
        ${config.services.postgresql.package}/bin/psql -d mailarchiver -f ${pkgs.writeText "mailarchiver-fts-index.sql" "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_archivedemails_fulltext_search ON mail_archiver.\"ArchivedEmails\" USING gin (to_tsvector('simple', COALESCE(\"Subject\", '') || ' ' || COALESCE(\"Body\", '') || ' ' || COALESCE(\"From\", '') || ' ' || COALESCE(\"To\", '') || ' ' || COALESCE(\"Cc\", '') || ' ' || COALESCE(\"Bcc\", '')));\n"}

        # Update table statistics after index creation
        ${config.services.postgresql.package}/bin/psql -d mailarchiver -c \
          'ANALYZE mail_archiver."ArchivedEmails";'
      fi
    '';
  };

  # Grant read-only access on the org database to the openclaw user.
  # This runs after mkPostgresUserSetup creates the user and sets its password.
  # Despite the unit name, the script below ALSO issues the flume-data grants:
  # read-only on `flume-data` for johnw and hass, and read-only on hass
  # states/states_meta for the flume-data role.
  systemd.services.postgresql-openclaw-org-grants = {
    description = "Grant read-only access on org database to openclaw user";
    after = [
      "postgresql.service"
      "postgresql-openclaw-setup.service"
    ];
    wants = [
      "postgresql.service"
      "postgresql-openclaw-setup.service"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for PostgreSQL to be ready
      until ${config.services.postgresql.package}/bin/psql -d org -c "SELECT 1" 2>/dev/null; do
        sleep 1
      done

      ${config.services.postgresql.package}/bin/psql -d org -c "GRANT CONNECT ON DATABASE org TO openclaw;"
      ${config.services.postgresql.package}/bin/psql -d org -c "GRANT USAGE ON SCHEMA public TO openclaw;"
      ${config.services.postgresql.package}/bin/psql -d org -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO openclaw;"
      ${config.services.postgresql.package}/bin/psql -d org -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO openclaw;"

      # Read-only access to the flume-data database for the johnw
      # OS user (peer auth). Same shape as the openclaw → org grant above:
      # CONNECT + USAGE on public + SELECT on current + future tables.
      ${config.services.postgresql.package}/bin/psql -d "flume-data" -c 'GRANT CONNECT ON DATABASE "flume-data" TO johnw;'
      ${config.services.postgresql.package}/bin/psql -d "flume-data" -c "GRANT USAGE ON SCHEMA public TO johnw;"
      ${config.services.postgresql.package}/bin/psql -d "flume-data" -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO johnw;"
      ${config.services.postgresql.package}/bin/psql -d "flume-data" -c "ALTER DEFAULT PRIVILEGES FOR ROLE \"flume-data\" IN SCHEMA public GRANT SELECT ON TABLES TO johnw;"

      # Read-only access on the flume-data database for the hass user
      # so HA's SQL sensor platform can read the per-fixture
      # attribution totals. Pairs with the `local flume-data hass peer`
      # pg_hba entry above.
      ${config.services.postgresql.package}/bin/psql -d "flume-data" -c 'GRANT CONNECT ON DATABASE "flume-data" TO hass;'
      ${config.services.postgresql.package}/bin/psql -d "flume-data" -c "GRANT USAGE ON SCHEMA public TO hass;"
      ${config.services.postgresql.package}/bin/psql -d "flume-data" -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO hass;"
      ${config.services.postgresql.package}/bin/psql -d "flume-data" -c "ALTER DEFAULT PRIVILEGES FOR ROLE \"flume-data\" IN SCHEMA public GRANT SELECT ON TABLES TO hass;"

      # Read-only access to the hass database for the flume-data role.
      # The v2 classifier reads valve.sprinkler_control_*_zone state
      # changes to build irrigation_sessions windows; segments overlapping
      # those windows are reclassified out of pool_autofill.
      ${config.services.postgresql.package}/bin/psql -d hass -c 'GRANT CONNECT ON DATABASE hass TO "flume-data";'
      ${config.services.postgresql.package}/bin/psql -d hass -c 'GRANT USAGE ON SCHEMA public TO "flume-data";'
      ${config.services.postgresql.package}/bin/psql -d hass -c 'GRANT SELECT ON states, states_meta TO "flume-data";'
    '';
  };

  # Optimize org database with performance indexes
  # Fixes PostgreSQLSlowQueries alert caused by sequential scans on entry_log_entries
  # Queries by time_day (date-based agenda lookups) had no index, causing 1307-block seqscans
  systemd.services.postgresql-org-optimize = {
    description = "Create performance indexes for org database";
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for PostgreSQL to be ready
      until ${config.services.postgresql.package}/bin/psql -d org -c "SELECT 1" 2>/dev/null; do
        sleep 1
      done

      # Index on time_day for date-based agenda queries
      # Without this, every date lookup scans all 71k rows (1307 buffers)
      ${config.services.postgresql.package}/bin/psql -d org -c \
        'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_log_entries_time_day ON entry_log_entries (time_day) WHERE time_day IS NOT NULL;'

      # Composite index for log_type + time_day queries (e.g. clock entries in a date range)
      ${config.services.postgresql.package}/bin/psql -d org -c \
        'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_log_entries_type_time_day ON entry_log_entries (log_type, time_day) WHERE time_day IS NOT NULL;'

      ${config.services.postgresql.package}/bin/psql -d org -c \
        'ANALYZE entry_log_entries;'
    '';
  };

  # Create the pg_stat_statements extension in the `postgres` database.
  #
  # The postgres-exporter connects database=postgres over /run/postgresql as
  # the postgres superuser (runAsLocalSuperUser=true). pg_stat_statements is
  # CLUSTER-WIDE, so a single CREATE EXTENSION here lets the exporter's
  # master:true custom query read per-statement stats for ALL 26 databases
  # from that one connection — no --auto-discover-databases (which would
  # re-activate the per-table collectors and explode cardinality).
  #
  # CREATE EXTENSION only SUCCEEDS once the .so is preloaded, i.e. AFTER the
  # planned restart that loads shared_preload_libraries. On a switch without a
  # restart it errors ("could not access file ... shared_preload_libraries")
  # and this oneshot is simply retried on the next boot/activation — harmless;
  # the pg_stat_statements_* metrics stay absent until the restart happens.
  # As of 2026-07-27 that restart HAS happened: the .so is preloaded and the
  # extension exists in the `postgres` database, so this oneshot now succeeds.
  systemd.services.postgresql-pgstatstatements-setup = {
    description = "Create pg_stat_statements extension in postgres DB";
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for PostgreSQL to be ready
      until ${config.services.postgresql.package}/bin/psql -d postgres -c "SELECT 1" 2>/dev/null; do
        sleep 1
      done

      ${config.services.postgresql.package}/bin/psql -d postgres -c \
        'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
    '';
  };

  # PostgreSQL boot ordering.
  #
  # `podman0` is created when the first podman container starts, which itself
  # depends on postgresql (chicken-and-egg). Treating podman0 as a hard
  # `Requires=` means postgresql fails permanently at boot if podman is slow,
  # cascading "dependency failed" to every pg-dependent unit (gitea, immich,
  # budget-board-server, etc. — observed 2026-05-21 boot).
  #
  # Soft ordering only: postgres is ordered AFTER podman0/end0 when they're
  # available, but does NOT require podman0. Containers reach postgres via
  # `host.containers.internal` (slirp4netns NAT to 127.0.0.1), not by binding
  # to 10.88.0.1, so postgres losing that bind at startup is harmless. end0
  # remains required because it's the host's primary interface.
  systemd.services.postgresql = {
    after = [
      "network-online.target"
      "sys-subsystem-net-devices-podman0.device"
      "sys-subsystem-net-devices-end0.device"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "sys-subsystem-net-devices-end0.device"
    ];
    # Retry on transient boot-time failures (mounts, device timeouts, etc.)
    # rather than entering a permanent "failed" state. Default StartLimitBurst=5
    # gives up after ~50s — boot can take much longer when slow disks or
    # network bridges are involved.
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkDefault "10s";
    };
    unitConfig = {
      StartLimitIntervalSec = lib.mkForce "10min";
      StartLimitBurst = lib.mkForce 30;
    };
  };

  # Boot-time resilience for pg-dependent services.
  #
  # When postgresql.service enters "failed" state, every unit with
  # `Requires=postgresql.service` (or `Requires=postgresql.target`) fails
  # immediately with "dependency failed" — and Restart= does NOT trigger,
  # because the service never reached ExecStart. They stay dead until manually
  # poked even after postgres recovers (observed 2026-05-21 boot cascade).
  #
  # Fix #1 above makes postgresql far less likely to fail. This block is
  # belt-and-braces: it lifts the default StartLimitBurst=5 / 10s on key
  # long-running pg-dependent services so they keep retrying when their own
  # ExecStartPre pg_isready checks time out during a slow postgres start.
  systemd.services.gitea.unitConfig = {
    StartLimitIntervalSec = "10min";
    StartLimitBurst = 30;
  };
  systemd.services.immich-server.unitConfig = {
    StartLimitIntervalSec = "10min";
    StartLimitBurst = 30;
  };
  systemd.services.immich-machine-learning.unitConfig = {
    StartLimitIntervalSec = "10min";
    StartLimitBurst = 30;
  };
  systemd.services.budget-board-server.unitConfig = {
    StartLimitIntervalSec = "10min";
    StartLimitBurst = 30;
  };
  systemd.services.pgadmin.unitConfig = {
    StartLimitIntervalSec = "10min";
    StartLimitBurst = 30;
  };
  systemd.services.home-assistant.unitConfig = {
    StartLimitIntervalSec = "10min";
    StartLimitBurst = 30;
  };
  systemd.services.nagios.unitConfig = {
    StartLimitIntervalSec = "10min";
    StartLimitBurst = 30;
  };

  networking.firewall = {
    allowedTCPPorts = lib.mkIf config.services.postgresql.enable [ 5432 ];
    interfaces.podman0.allowedTCPPorts = lib.mkIf config.services.postgresql.enable [ 5432 ];
  };
}
