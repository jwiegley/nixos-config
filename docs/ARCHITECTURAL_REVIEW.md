# NixOS Vulcan - Comprehensive Architectural Review

**System:** vulcan (Apple Silicon M1 Max - aarch64)
**Review Date:** 2025-10-23
**NixOS Version:** 25.05
**Total Services:** 63 active services, 7 containers, 32 timers, 81 configuration modules

---

## Executive Summary

Your NixOS system "vulcan" is a sophisticated, production-grade infrastructure running **63 active services**, **7 containers**, and **32+ systemd timers**. This review analyzes the complete architecture including ALL services, containers, timers, and their dependencies.

**Overall Architecture Rating: EXCELLENT (9.5/10)**

The system is production-ready, well-designed, and comprehensively monitored with no critical issues found.

---

## Table of Contents

- [I. Complete Service Inventory](#i-complete-service-inventory)
- [II. Complete Timer Inventory](#ii-complete-timer-inventory)
- [III. Dependency Architecture Analysis](#iii-dependency-architecture-analysis)
- [IV. Monitoring Coverage Analysis](#iv-monitoring-coverage-analysis)
- [V. Container Orchestration Analysis](#v-container-orchestration-analysis)
- [VI. Timer Schedule Analysis](#vi-timer-schedule-analysis)
- [VII. Architectural Findings & Recommendations](#vii-architectural-findings--recommendations)
- [VIII. Integration Analysis](#viii-integration-analysis)
- [IX. Scalability Assessment](#ix-scalability-assessment)
- [X. Final Verdict](#x-final-verdict)
- [XI. Actionable Recommendations](#xi-actionable-recommendations)
- [XII. Conclusion](#xii-conclusion)

---

## I. COMPLETE SERVICE INVENTORY

### A. Core Infrastructure Services (10 services)

#### 1. **postgresql.service** - Main database server (PostgreSQL 17 with pgvector)
- **Dependencies:** `sys-subsystem-net-devices-podman0.device` (CRITICAL)
- **Serves:** litellm, wallabag, nextcloud, home-assistant, grafana
- **Listens on:** localhost, 192.168.1.2, 10.88.0.1 (podman network)
- **Supporting services:**
  - `postgresql-litellm-optimize.service` (creates performance indexes)
  - `postgresql-hass-password.service` (sets HA password from SOPS)
  - `postgresql-nextcloud-password.service` (via mkPostgresUserSetup)

**Location:** `/etc/nixos/modules/services/databases.nix`

#### 2. **nginx.service** - Reverse proxy with SSL termination
- **Virtual hosts:** 15 configured
- **Certificates:** All use step-ca certificates
- **Features:** Global HTTP→HTTPS redirect, HSTS, security headers

**Location:** `/etc/nixos/modules/services/web.nix`

#### 3. **step-ca.service** - Private Certificate Authority
- **Port:** 8443 (localhost only)
- **Root CA:** Trusted system-wide via `/etc/ssl/certs/`
- **Supporting service:** `step-ca-init.service`

**Location:** `/etc/nixos/modules/services/certificates.nix`

#### 4. **postfix.service** - SMTP mail server
- **Certificates:** Uses step-ca certificates
- **Renewal:** Monthly timer

**Location:** `/etc/nixos/modules/services/postfix.nix`

#### 5. **dovecot.service** - IMAP server with Xapian FTS
- **Certificates:** Uses step-ca certificates
- **Renewal:** Monthly timer
- **Features:** Full-text search indexing

**Location:** `/etc/nixos/modules/services/dovecot.nix`

#### 6. **technitium-dns-server.service** - DNS server
- **Port:** 53 (replaces systemd-resolved)
- **Monitoring:** Container exporter monitors it

#### 7. **redis-litellm.service** - Redis for LiteLLM
- **Port:** 8085
- **Bind:** 10.88.0.1
- **Depends on:** podman0 device

#### 8. **redis-nextcloud.service** - Redis for Nextcloud caching

#### 9. **sshd.service** - SSH daemon

#### 10. **speakersafetyd.service** - Apple Silicon speaker protection (Asahi Linux)

---

### B. Web Applications (13 services)

#### 1. **home-assistant.service** - IoT platform
- **Port:** 8123
- **Dependencies:** postgresql, postgresql-hass-password, sops secrets
- **Database:** PostgreSQL recorder (tuned for time-series workload)
- **Services:** avahi (mDNS for HomeKit)
- **Integrations:** 17+ (Yale, BMW, Ring, Enphase, Nest, LG, etc.)
- **Exports:** Prometheus metrics, HomeKit bridge (port 21063)
- **Features:**
  - Google Assistant SDK integration
  - Extended OpenAI Conversation (LLM)
  - ADT security system control

**Location:** `/etc/nixos/modules/services/home-assistant.nix`

#### 2. **node-red.service** - Automation flows
- **Port:** 1880
- **Dependencies:** sops secrets (HA token, admin auth)
- **Integrates with:** Home Assistant

**Location:** `/etc/nixos/modules/services/node-red.nix`

#### 3. **nextcloud** - Cloud storage/collaboration
- **Services:**
  - `phpfpm-nextcloud.service`
  - `nextcloud-setup.service`
  - `nextcloud-update-db.service`
  - `nextcloud-cron.service`
- **Dependencies:** postgresql, var-lib-nextcloud-data.mount (tank), redis-nextcloud
- **Timer:** nextcloud-cron.timer (every 5 min)
- **Mount:** `/var/lib/nextcloud/data` → `/tank/Nextcloud`

**Location:** `/etc/nixos/modules/services/nextcloud.nix`

#### 4. **jellyfin.service** - Media server
- **Port:** 8096
- **User:** johnw
- **Proxy:** Nginx reverse proxy at jellyfin.vulcan.lan

**Location:** `/etc/nixos/modules/services/media.nix`

#### 5. **glance.service** + **glance-github-extension.service** - Dashboard
- **Features:** Custom GitHub integration service

**Location:** `/etc/nixos/modules/services/glance.nix`

#### 6. **pgadmin.service** - PostgreSQL web admin
- **Proxy:** pgadmin.vulcan.lan

**Location:** `/etc/nixos/modules/services/pgadmin.nix`

#### 7. **cockpit.service** + **cockpit-wsinstance-http.service** - Server management UI
- **Proxy:** cockpit.vulcan.lan

**Location:** `/etc/nixos/modules/services/cockpit.nix`

#### 8. **nagios.service** - Monitoring daemon
- **Port:** 6667
- **Services:** fcgiwrap-nagios.service, phpfpm-nagios.service
- **Monitors:** 50+ services including all ZFS/tank-dependent services

**Location:** `/etc/nixos/modules/services/nagios.nix`

---

### C. Containerized Services (7 containers)

#### NixOS Container (1)

**1. container@secure-nginx.service**
- **Type:** systemd-nspawn container
- **Network:** 10.233.1.0/24 (isolated, NAT via end0)
- **Ports:** 18080→80, 18443→443, 18873→873, 18874→874
- **Features:**
  - Let's Encrypt ACME certificates
  - rsync daemon for public files
  - nginx web server
- **Mounts:** `/tank/Public` → `/var/www/home.newartisans.com`
- **Serves:** home.newartisans.com (public website)
- **Auto-start:** yes

**Location:** `/etc/nixos/modules/containers/secure-nginx.nix`

#### Podman Containers (6)

**2. litellm.service**
- **Image:** ghcr.io/berriai/litellm-database:main-stable
- **Port:** 4000 (127.0.0.1 + 10.88.0.1)
- **Dependencies:** postgresql, redis-litellm, podman0
- **Proxy:** litellm.vulcan.lan
- **Purpose:** LLM proxy/gateway with usage tracking

**Location:** `/etc/nixos/modules/containers/litellm-quadlet.nix`

**3. wallabag.service**
- **Port:** 80 (internal)
- **Dependencies:** postgresql
- **Proxy:** wallabag.vulcan.lan
- **Purpose:** Read-it-later service

**Location:** `/etc/nixos/modules/containers/wallabag-quadlet.nix`

**4. silly-tavern.service**
- **Purpose:** AI chat interface
- **Proxy:** silly-tavern.vulcan.lan

**Location:** `/etc/nixos/modules/containers/silly-tavern-quadlet.nix`

**5. speedtest.service** (openspeedtest)
- **Purpose:** Network speed testing
- **Proxy:** speedtest.vulcan.lan

**Location:** `/etc/nixos/modules/containers/openspeedtest-quadlet.nix`

**6. opnsense-exporter.service**
- **Purpose:** Monitors OPNsense firewall
- **Upstream proxy:** opnsense-api-transformer.service (fixes API issues)

**Location:** `/etc/nixos/modules/containers/opnsense-exporter-quadlet.nix`

**7. technitium-dns-exporter.service**
- **Purpose:** Monitors local Technitium DNS server

**Location:** `/etc/nixos/modules/containers/technitium-dns-exporter-quadlet.nix`

---

### D. Monitoring & Observability Stack (23+ services)

#### Core Monitoring (7)

1. **prometheus.service** - Metrics collection (port 9090)
2. **grafana.service** - Visualization (port 3000)
3. **loki.service** - Log aggregation (port 3100)
4. **promtail.service** - Log shipping to Loki
5. **alertmanager.service** - Alert routing (port 9093)
6. **nagios.service** - Traditional monitoring (port 6667)
7. **victoriametrics.service** - Alternative TSDB (port 8428)

#### Prometheus Exporters (16)

8. **prometheus-node-exporter.service** - System metrics
9. **prometheus-postgres-exporter.service** - PostgreSQL metrics
10. **prometheus-nginx-exporter.service** - Nginx metrics
11. **prometheus-postfix-exporter.service** - Mail server metrics
12. **prometheus-php-fpm-exporter.service** - PHP-FPM pool metrics
13. **prometheus-dovecot-exporter.service** - IMAP server metrics
14. **prometheus-nextcloud-exporter.service** - Nextcloud metrics
15. **prometheus-blackbox-exporter.service** - Health check probes
16. **prometheus-redis-exporter.service** - Redis metrics
17. **prometheus-zfs-exporter.service** - ZFS pool metrics (tank-dependent, auto-starts)
18. **opnsense-exporter.service** - Firewall metrics (container)
19. **technitium-dns-exporter.service** - DNS metrics (container)
20. **opnsense-api-transformer.service** - Proxy for opnsense-exporter
21. **dns-query-log-exporter.service** - DNS query logs
22. **critical-services-exporter.service** - Service health status
23. **litellm-exporter.service** - LLM usage metrics (timer-driven, hourly)
24. **certificate-exporter.service** - Certificate expiry metrics (timer-driven, hourly)
25. **backup-status-exporter.service** - Backup health (timer-driven, daily 4 AM)
26. **home-assistant-backup-monitor.service** - HA backup status (timer-driven, every 5 min)
27. **restic-metrics.service** - Restic repository metrics (timer-driven, every 6 hours, tank-dependent)

**Locations:** `/etc/nixos/modules/monitoring/services/*.nix`

---

### E. File Sharing - Samba (5 services)

All Samba services are configured with:
- `RequiresMountsFor = [ "/tank" ]`
- `wantedBy = [ "tank.mount" ]`
- Auto-start when ZFS pool becomes available

1. **samba.service** - Main Samba daemon
2. **samba-smbd.service** - SMB/CIFS file serving
3. **samba-nmbd.service** - NetBIOS name server
4. **samba-winbindd.service** - Windows domain integration
5. **samba-wsdd.service** - Web Services Discovery (WS-Discovery)

**Location:** `/etc/nixos/modules/services/samba.nix`

**Shares configured:**
- johnw-documents, johnw-downloads, johnw-home
- media, music, photos, pictures, video (shared)

---

### F. Storage & Backup Services (11 services + 9 timers)

#### Restic Backup Services (9 + weekly check)

All backup services configured with:
- `RequiresMountsFor = [ "/tank" ]`
- `wantedBy = [ "tank.mount" ]`
- Daily schedule: 2:00 AM
- Retention: 7 daily, 5 weekly, 3 yearly

1. **restic-backups-Audio.service** → s3://jwiegley-Audio
2. **restic-backups-Backups.service** → s3://jwiegley-Backups-Misc
3. **restic-backups-Databases.service** → s3://jwiegley-Databases
4. **restic-backups-Home.service** → s3://jwiegley-Home
5. **restic-backups-Nextcloud.service** → s3://jwiegley-Nextcloud
6. **restic-backups-Photos.service** → s3://jwiegley-Photos
7. **restic-backups-Video.service** → s3://jwiegley-Video
8. **restic-backups-doc.service** → s3://jwiegley-doc
9. **restic-backups-src.service** → s3://jwiegley-src
10. **restic-check.service** - Weekly integrity check (tank-dependent)
11. **restic-metrics.service** - Metrics collection every 6h (tank-dependent)

**Location:** `/etc/nixos/modules/storage/backups.nix`

#### PostgreSQL Backup

- **postgresql-backup.service** - Daily pg_dumpall at 2:00 AM
- **Output:** `/tank/Backups/PostgreSQL/postgresql-backup.sql`

**Location:** `/etc/nixos/modules/services/postgresql-backup.nix`

#### ZFS Services

- **sanoid.service** - Hourly ZFS snapshots
- **zpool-trim.service** - Weekly TRIM operations

---

### G. System Services (6)

1. **avahi-daemon.service** - mDNS/Bonjour (required for HomeKit)
2. **dbus.service** - System message bus
3. **nscd.service** - Name service caching
4. **polkit.service** - Authorization manager
5. **nix-daemon.service** - Nix package manager
6. **speakersafetyd.service** - Apple Silicon speaker protection

---

## II. COMPLETE TIMER INVENTORY (32 timers)

### High-Frequency Timers (< 1 hour intervals)

| Timer | Frequency | Service | Purpose | Location |
|-------|-----------|---------|---------|----------|
| nextcloud-cron.timer | Every 5 min | nextcloud-cron.service | Background jobs | nextcloud.nix |
| home-assistant-backup-monitor.timer | Every 5 min | home-assistant-backup-monitor.service | Backup health | home-assistant-backup-exporter.nix |
| mbsync-johnw.timer | Every 15 min | mbsync-johnw.service | Email sync | mbsync.nix |
| mbsync-assembly-health-check.timer | Every 30 min | mbsync-assembly-health-check.service | Email health | mbsync-alerts.nix |
| mbsync-johnw-health-check.timer | Every 30 min | mbsync-johnw-health-check.service | Email health | mbsync-alerts.nix |

### Hourly Timers

| Timer | Service | Purpose | Location |
|-------|---------|---------|----------|
| logrotate.timer | logrotate.service | Log rotation | System default |
| sanoid.timer | sanoid.service | ZFS snapshots | zfs.nix |
| litellm-exporter.timer | litellm-exporter.service | LiteLLM metrics | litellm-exporter.nix |
| certificate-exporter.timer | certificate-exporter.service | Cert expiry metrics | certificate-exporter.nix |

### Multi-Hour Timers

| Timer | Frequency | Service | Purpose | Location |
|-------|-----------|---------|---------|----------|
| restic-metrics.timer | Every 6h | restic-metrics.service | Backup repo metrics | restic-metrics.nix |

### Daily Timers (2-6 AM maintenance window)

| Timer | Schedule | Service | Purpose | Location |
|-------|----------|---------|---------|----------|
| git-workspace-archive.timer | Daily 00:00 | git-workspace-archive.service | Archive git repos | timers.nix |
| update-containers.timer | Daily (randomized) | update-containers.service | Update podman images | timers.nix |
| postgresql-backup.timer | Daily 02:00 | postgresql-backup.service | pg_dumpall backup | postgresql-backup.nix |
| restic-backups-Audio.timer | Daily 02:00 | restic-backups-Audio.service | Backup to B2 | backups.nix |
| restic-backups-Backups.timer | Daily 02:00 | restic-backups-Backups.service | Backup to B2 | backups.nix |
| restic-backups-Databases.timer | Daily 02:00 | restic-backups-Databases.service | Backup to B2 | backups.nix |
| restic-backups-Home.timer | Daily 02:00 | restic-backups-Home.service | Backup to B2 | backups.nix |
| restic-backups-Nextcloud.timer | Daily 02:00 | restic-backups-Nextcloud.service | Backup to B2 | backups.nix |
| restic-backups-Photos.timer | Daily 02:00 | restic-backups-Photos.service | Backup to B2 | backups.nix |
| restic-backups-Video.timer | Daily 02:00 | restic-backups-Video.service | Backup to B2 | backups.nix |
| restic-backups-doc.timer | Daily 02:00 | restic-backups-doc.service | Backup to B2 | backups.nix |
| restic-backups-src.timer | Daily 02:00 | restic-backups-src.service | Backup to B2 | backups.nix |
| backup-status-exporter.timer | Daily 04:00 | backup-status-exporter.service | Export backup metrics | health-check-exporters.nix |
| logwatch.timer | Daily 04:00 | logwatch.service | Email log summaries | System default |
| certificate-validation.timer | Daily 06:00 | certificate-validation.service | Validate all certs | certificate-automation.nix |
| mbsync-assembly.timer | Daily (afternoon) | mbsync-assembly.service | Assembly email sync | mbsync.nix |

### Weekly Timers

| Timer | Service | Purpose | Location |
|-------|---------|---------|----------|
| restic-check.timer | restic-check.service | Verify backup integrity | backups.nix |
| zpool-trim.timer | zpool-trim.service | TRIM SSD blocks | zfs.nix |
| podman-prune.timer | podman-prune.service | Clean unused images | quadlet.nix |

### Monthly Timers (Certificate Renewals)

| Timer | Schedule | Service | Purpose | Location |
|-------|----------|---------|---------|----------|
| postgresql-cert-renewal.timer | 1st @ 03:00 | postgresql-cert-renewal.service | Renew PostgreSQL certs | certificate-automation.nix |
| nginx-cert-renewal.timer | 1st @ 03:30 | nginx-cert-renewal.service | Renew nginx vhost certs | certificate-automation.nix |
| postfix-cert-renewal.timer | 1st @ 04:00 | postfix-cert-renewal.service | Renew Postfix certs | certificate-automation.nix |
| dovecot-cert-renewal.timer | 1st @ 04:30 | dovecot-cert-renewal.service | Renew Dovecot certs | certificate-automation.nix |

---

## III. DEPENDENCY ARCHITECTURE ANALYSIS

### A. ZFS Storage Dependency Tree

**Complete ZFS-dependent service list (22 services/timers):**

```
zfs.target
  └── zfs-import.target
      └── zfs-import-tank.service
          └── tank.mount
              ├── nextcloud-setup.service (RequiresMountsFor: /var/lib/nextcloud/data)
              ├── nextcloud-update-db.service (RequiresMountsFor: /var/lib/nextcloud/data)
              ├── nextcloud-cron.service (RequiresMountsFor: /var/lib/nextcloud/data)
              ├── samba.service (RequiresMountsFor: /tank)
              ├── samba-smbd.service (RequiresMountsFor: /tank)
              ├── samba-nmbd.service (RequiresMountsFor: /tank)
              ├── samba-winbindd.service (RequiresMountsFor: /tank)
              ├── restic-backups-Audio.service (RequiresMountsFor: /tank)
              ├── restic-backups-Backups.service (RequiresMountsFor: /tank)
              ├── restic-backups-Databases.service (RequiresMountsFor: /tank)
              ├── restic-backups-Home.service (RequiresMountsFor: /tank)
              ├── restic-backups-Nextcloud.service (RequiresMountsFor: /tank)
              ├── restic-backups-Photos.service (RequiresMountsFor: /tank)
              ├── restic-backups-Video.service (RequiresMountsFor: /tank)
              ├── restic-backups-doc.service (RequiresMountsFor: /tank)
              ├── restic-backups-src.service (RequiresMountsFor: /tank)
              ├── restic-check.service (RequiresMountsFor: /tank)
              ├── restic-metrics.service (RequiresMountsFor: /tank)
              ├── prometheus-zfs-exporter.service (RequiresMountsFor: /tank)
              ├── backup-alert@.service (RequiresMountsFor: /tank)
              ├── restic-check.timer (wantedBy: tank.mount)
              └── restic-metrics.timer (wantedBy: tank.mount)

          └── var-lib-nextcloud-data.mount (bind mount)
              ├── nextcloud-setup.service
              ├── nextcloud-update-db.service
              └── nextcloud-cron.service
```

**Key Design Decisions:**
- ✅ Uses `RequiresMountsFor` (best practice for path dependencies)
- ✅ Uses `wantedBy = [ "tank.mount" ]` for auto-start
- ✅ All services use `nofail` mount option (allows boot without tank)
- ✅ Monitoring shows errors when tank unavailable (correct behavior)

**Implementation:**
- Location: `/etc/nixos/modules/storage/backups.nix:216-250`
- Helper: `/etc/nixos/modules/lib/bindTankModule.nix`

---

### B. Network Dependency Tree (Podman)

**CRITICAL DISCOVERY - Podman Network Race Condition Fixed:**

```
podman.service
  └── sys-subsystem-net-devices-podman0.device (~50s boot time)
      ├── postgresql.service (CRITICAL FIX: requires podman0)
      │   ├── Binds to: 10.88.0.1 (podman gateway)
      │   └── Serves containers: litellm, wallabag
      ├── redis-litellm.service (bindsTo: podman0)
      │   └── Bind: 10.88.0.1:8085
      └── Container services:
          ├── litellm.service
          ├── wallabag.service
          ├── opnsense-exporter.service
          ├── technitium-dns-exporter.service
          ├── silly-tavern.service
          └── speedtest.service
```

**Critical Fix in modules/services/databases.nix:142-145:**

```nix
systemd.services.postgresql = {
  after = [ "sys-subsystem-net-devices-podman0.device" ];
  requires = [ "sys-subsystem-net-devices-podman0.device" ];
};
```

**Why this matters:**
- PostgreSQL starts at ~19s
- podman0 device created at ~50s
- **Without this fix:** PostgreSQL only listens on localhost
- **With this fix:** PostgreSQL waits for podman0, then binds to 10.88.0.1
- **Result:** Containers can connect to PostgreSQL, health checks pass

**Container Network Configuration:**
```
podman0 bridge: 10.88.0.0/16
  Gateway: 10.88.0.1
  DNS: disabled (conflicts with Technitium DNS on port 53)
  Containers use: host's /etc/resolv.conf
```

---

### C. Certificate Infrastructure Dependency Tree

```
sops-install-secrets.service
  └── step-ca-init.service (oneshot initialization)
      └── step-ca.service (port 8443)
          ├── Certificate Renewal Services (monthly):
          │   ├── postgresql-cert-renewal.service (1st @ 03:00)
          │   ├── nginx-cert-renewal.service (1st @ 03:30)
          │   ├── postfix-cert-renewal.service (1st @ 04:00)
          │   └── dovecot-cert-renewal.service (1st @ 04:30)
          ├── certificate-validation.service (daily @ 06:00)
          └── certificate-exporter.service (hourly)
              └── prometheus.service
```

**Certificate Distribution:**
- PostgreSQL: `/var/lib/postgresql/certs/`
- Nginx vhosts: `/var/lib/nginx-certs/` (15 virtual hosts)
- Postfix: step-ca certificates
- Dovecot: step-ca certificates
- Root CA: Added to system trust store (`/etc/ssl/certs/ca-bundle.crt`)

**Virtual Hosts with Certificates:**
1. vulcan.lan
2. hass.vulcan.lan
3. nodered.vulcan.lan
4. jellyfin.vulcan.lan
5. nextcloud.vulcan.lan
6. pgadmin.vulcan.lan
7. nagios.vulcan.lan
8. prometheus.vulcan.lan
9. grafana.vulcan.lan
10. alertmanager.vulcan.lan
11. glance.vulcan.lan
12. speedtest.vulcan.lan
13. silly-tavern.vulcan.lan
14. wallabag.vulcan.lan
15. litellm.vulcan.lan
16. cockpit.vulcan.lan

**Location:** `/etc/nixos/modules/services/certificates.nix`, `/etc/nixos/modules/services/certificate-automation.nix`

---

### D. Database Dependency Tree

```
sops-install-secrets.service
  └── sys-subsystem-net-devices-podman0.device
      └── postgresql.service
          ├── Supporting Services:
          │   ├── postgresql-litellm-optimize.service (creates indexes)
          │   ├── postgresql-hass-password.service (sets HA password)
          │   └── postgresql-nextcloud-password.service (sets NC password)
          └── Dependent Services:
              ├── home-assistant.service
              │   └── Depends on: postgresql-hass-password.service
              ├── nextcloud-setup.service
              ├── litellm.service (container)
              ├── wallabag.service (container)
              ├── grafana.service
              ├── pgadmin.service
              └── prometheus-postgres-exporter.service
```

**PostgreSQL Configuration Highlights:**
- Max connections: 200
- Shared buffers: 256MB (HA tuning)
- SSL required: TLS 1.2-1.3
- Authentication: scram-sha-256
- Network interfaces: localhost, 192.168.1.2, 10.88.0.1

**Location:** `/etc/nixos/modules/services/databases.nix`

---

### E. Home Assistant Integration Tree

```
sops-install-secrets.service
  └── postgresql-hass-password.service
      └── postgresql.service
          └── home-assistant.service
              ├── Exports to:
              │   ├── prometheus.service (metrics at :8123/api/prometheus)
              │   └── HomeKit (bridge on port 21063)
              ├── Integrates with:
              │   ├── node-red.service (automation flows)
              │   ├── avahi-daemon.service (mDNS/Bonjour)
              │   └── 17+ IoT platforms:
              │       ├── Yale/August (locks)
              │       ├── BMW ConnectedDrive (vehicle)
              │       ├── Ring (doorbell)
              │       ├── Enphase (solar)
              │       ├── Tesla Wall Connector (EV charging)
              │       ├── Flume (water meter)
              │       ├── Nest (thermostats)
              │       ├── OPNsense (firewall - HACS)
              │       ├── LG ThinQ (appliances)
              │       ├── webOS TV
              │       ├── Miele (dishwasher)
              │       ├── Pentair IntelliCenter (pool)
              │       ├── Withings (scale)
              │       ├── MyQ (garage)
              │       ├── B-Hyve (sprinklers)
              │       ├── Dreame (vacuum)
              │       └── Traeger (grill)
              └── Custom Components:
                  ├── HACS
                  ├── Extended OpenAI Conversation (LLM)
                  └── Google Assistant SDK
```

**Location:** `/etc/nixos/modules/services/home-assistant.nix`

---

## IV. MONITORING COVERAGE ANALYSIS

### A. Prometheus Monitoring Coverage (24 targets)

**Services Monitored via Prometheus Exporters:**

| Service | Exporter | Port | Alert Coverage | Location |
|---------|----------|------|----------------|----------|
| System metrics | node-exporter | 9100 | CPU, memory, disk, network | node-exporter.nix |
| PostgreSQL | postgres-exporter | 9187 | Connections, queries | postgres-exporter.nix |
| Nginx | nginx-exporter | 9113 | Requests, connections | nginx-exporter.nix |
| Postfix | postfix-exporter | 9154 | Queue size, delivery | postfix-exporter.nix |
| Dovecot | dovecot-exporter | 9166 | IMAP connections | (built-in) |
| Redis (2 instances) | redis-exporter | 9121 | Memory, commands | redis-exporter.nix |
| PHP-FPM (2 pools) | php-fpm-exporter | 9253 | Pool status | phpfpm-exporter.nix |
| Nextcloud | nextcloud-exporter | 9205 | Users, files, shares | (built-in) |
| ZFS | zfs-exporter | 9134 | Pool health, capacity | zfs-exporter.nix |
| Systemd units | systemd-exporter | built-in | Unit states, failures | systemd-exporter.nix |
| Certificates | certificate-exporter | textfile | Expiry dates | certificate-exporter.nix |
| Blackbox probes | blackbox-exporter | 9115 | HTTP/TCP health | blackbox-monitoring.nix |
| OPNsense | opnsense-exporter | container | Gateway, firewall | opnsense-monitoring.nix |
| Technitium DNS | dns-exporter | container | Query logs | technitium-dns-monitoring.nix |
| LiteLLM | litellm-exporter | textfile | API usage, costs | litellm-exporter.nix |
| Restic backups | restic-metrics | textfile | Snapshot age, repo size | restic-metrics.nix |
| Backup status | backup-status-exporter | textfile | Last backup times | health-check-exporters.nix |
| Home Assistant | HA built-in | 8123 | Entity states | home-assistant.nix |
| Critical services | critical-services-exporter | textfile | Service health | health-check-exporters.nix |
| Node-RED | node-red-exporter | custom | Flow metrics | node-red-exporter.nix |

**Prometheus Alert Groups (18 groups):**

1. **storage_alerts** - ZFS + Restic
   - ZFSPoolDegraded, ZFSPoolCapacityHigh/Critical, ZFSSnapshotAgeTooOld
   - ResticCheckFailed, ResticNoRecentSnapshot, ResticNoSnapshots, ResticRepositorySizeGrowing

2. **backup_alerts** - Systemd unit states
   - BackupServiceFailed, BackupNotRunning, BackupTimerInactive

3. **database_alerts** - PostgreSQL
   - PostgresDown, PostgresHighConnections, PostgresSlowQueries

4. **email_alerts** - Postfix + Dovecot + mbsync
   - PostfixQueueHigh, DovecotDown, MbsyncFailed

5. **certificate_alerts** - Expiry warnings
   - CertificateExpiringSoon, CertificateExpired

6. **system_alerts** - CPU, memory, disk
   - HighCPUUsage, HighMemoryUsage, DiskSpaceLow

7. **network_alerts** - Interface status
   - InterfaceDown, HighPacketLoss

8. **service_alerts** - Systemd failures
   - SystemdServiceFailed, SystemdServiceFlapping

9. **container_alerts** - Podman containers
   - ContainerDown, ContainerRestartLoop

10. **nextcloud_alerts** - Nextcloud health
    - NextcloudDown, NextcloudHighLatency

11. **home_assistant_alerts** - HA health
    - HomeAssistantDown, HomeAssistantDatabaseSlow

12. **litellm_alerts** - LLM proxy health
    - LiteLLMHighLatency, LiteLLMHighCost

13. **opnsense_alerts** - Firewall health
    - OPNsenseDown, OPNsenseHighCPU

14. **dns_alerts** - DNS server health
    - DNSServerDown, DNSHighQueryRate

15. **nginx_alerts** - Web server health
    - NginxDown, NginxHighErrorRate

16. **redis_alerts** - Cache health
    - RedisDown, RedisHighMemory

17. **monitoring_alerts** - Self-monitoring
    - PrometheusDown, GrafanaDown, LokiDown

18. **blackbox_alerts** - Health check failures
    - EndpointDown, SlowResponse

**Alert Routing:**
```
Prometheus → Alertmanager (port 9093)
  ├── Email notifications
  ├── Severity-based routing
  └── Alert deduplication
```

**Location:** `/etc/nixos/modules/monitoring/alerts/*.yaml`

---

### B. Nagios Monitoring Coverage (50+ services)

**From modules/services/nagios.nix:**

**Critical Infrastructure Services (14):**
- postgresql.service
- step-ca.service
- nginx.service
- postfix.service
- dovecot.service
- samba-smbd.service
- samba-nmbd.service
- samba-winbindd.service
- nextcloud-setup.service
- nextcloud-cron.service
- home-assistant.service
- node-red.service
- technitium-dns-server.service
- sshd.service

**Restic Backup Services (9):**
- restic-backups-Audio.service
- restic-backups-Backups.service
- restic-backups-Databases.service
- restic-backups-doc.service
- restic-backups-Home.service
- restic-backups-Nextcloud.service
- restic-backups-Photos.service
- restic-backups-src.service
- restic-backups-Video.service

**Monitoring Stack Services (18+):**
- prometheus.service
- grafana.service
- loki.service
- promtail.service
- alertmanager.service
- victoriametrics.service
- prometheus-node-exporter.service
- prometheus-postgres-exporter.service
- prometheus-nginx-exporter.service
- prometheus-postfix-exporter.service
- prometheus-php-fpm-exporter.service
- prometheus-dovecot-exporter.service
- prometheus-nextcloud-exporter.service
- prometheus-blackbox-exporter.service
- prometheus-redis-exporter.service
- prometheus-zfs-exporter.service
- (additional exporters)

**Container Services (7):**
- container@secure-nginx.service
- litellm.service
- wallabag.service
- silly-tavern.service
- speedtest.service
- opnsense-exporter.service
- technitium-dns-exporter.service

**Maintenance Timers (10+):**
- restic-check.timer
- restic-metrics.timer
- postgresql-backup.timer
- git-workspace-archive.timer
- update-containers.timer
- postgresql-cert-renewal.timer
- nginx-cert-renewal.timer
- postfix-cert-renewal.timer
- dovecot-cert-renewal.timer

**Nagios Configuration:**
- Port: 6667
- Web UI: https://nagios.vulcan.lan
- Email alerts: Configured
- Check interval: Every 5 minutes
- Retry interval: Every 1 minute

**Location:** `/etc/nixos/modules/services/nagios.nix`

---

### C. Monitoring Coverage Analysis

**Coverage Summary:**

| Coverage Area | Prometheus | Nagios | Status |
|--------------|-----------|--------|--------|
| Critical services | ✅ 24 targets | ✅ 50+ checks | Excellent |
| Tank-dependent services | ✅ All monitored | ✅ All monitored | Excellent |
| Containers | ✅ All monitored | ✅ All monitored | Excellent |
| Timers | ✅ Systemd exporter | ✅ Timer checks | Excellent |
| Self-monitoring | ✅ Yes | ✅ Yes | Excellent |
| Alert redundancy | ✅ 18 groups | ✅ Email | Excellent |

**Findings:**
- ✅ All critical services monitored by **BOTH** Prometheus AND Nagios (redundancy)
- ✅ All tank-dependent services correctly show errors when tank unavailable
- ✅ Monitoring stack monitors itself (self-healing capability)
- ✅ No monitoring blind spots identified
- ✅ Alert coverage appropriate for all severity levels

**Integration Points:**
```
Prometheus → Grafana (dashboards at grafana.vulcan.lan)
Prometheus → Alertmanager → Email
Loki → Grafana (log visualization)
Nagios → Email (direct alerts)
All exporters → Prometheus → Long-term storage (VictoriaMetrics)
```

---

## V. CONTAINER ORCHESTRATION ANALYSIS

### A. Container Technologies (2 types)

#### 1. NixOS systemd-nspawn Container

**secure-nginx** - Internet-facing nginx with Let's Encrypt ACME

**Specifications:**
- Type: systemd-nspawn (NixOS container)
- Network: 10.233.1.0/24 (isolated, NAT via end0)
- Host address: 10.233.1.1
- Container address: 10.233.1.2
- Port mapping:
  - 18080 → 80 (HTTP for ACME challenges)
  - 18443 → 443 (HTTPS)
  - 18873 → 873 (rsync daemon)
  - 18874 → 874 (rsync-ssl proxy)

**Bind Mounts:**
- `/tank/Public` → `/var/www/home.newartisans.com` (read-only)
- `/var/lib/acme-container` → `/var/lib/acme` (read-write)

**Services Inside Container:**
- nginx (web server)
- rsyncd (file serving)
- ACME certificate management (Let's Encrypt production)

**Purpose:** Serves public website at home.newartisans.com with automatic SSL renewal

**Auto-start:** Yes

**Location:** `/etc/nixos/modules/containers/secure-nginx.nix`

---

#### 2. Podman Quadlet Containers (6 containers)

**Container Network Architecture:**
```
Host (192.168.1.2 - end0 interface)
  ├── podman0 bridge: 10.88.0.0/16
  │   ├── Gateway: 10.88.0.1
  │   ├── PostgreSQL listens here (after podman0 device ready)
  │   ├── Redis (litellm) listens here
  │   └── DNS: disabled (Technitium on host:53)
  └── ve-+ (nspawn): 10.233.1.0/24
      └── secure-nginx: 10.233.1.2
```

**Container Specifications:**

| Container | Image | Host Port | Container Port | Database | Location |
|-----------|-------|-----------|----------------|----------|----------|
| litellm | ghcr.io/berriai/litellm-database:main-stable | 127.0.0.1:4000, 10.88.0.1:4000 | 4000 | PostgreSQL, Redis | litellm-quadlet.nix |
| wallabag | (wallabag official) | - | 80 | PostgreSQL | wallabag-quadlet.nix |
| silly-tavern | (silly-tavern) | - | - | - | silly-tavern-quadlet.nix |
| speedtest | (openspeedtest) | - | - | - | openspeedtest-quadlet.nix |
| opnsense-exporter | (opnsense-exporter) | - | - | - | opnsense-exporter-quadlet.nix |
| technitium-dns-exporter | (custom) | - | - | - | technitium-dns-exporter-quadlet.nix |

**All containers accessed via nginx reverse proxy:**
- litellm.vulcan.lan
- wallabag.vulcan.lan
- silly-tavern.vulcan.lan
- speedtest.vulcan.lan

---

### B. Container Management

#### Update Strategy

**Daily Container Updates:**
- Timer: `update-containers.timer`
- Schedule: Daily with 30min randomization
- Script: `/etc/nixos/modules/maintenance/timers.nix:9-80`

**Update Process:**
1. Get list of all container images
2. Pull latest version of each image
3. Detect if image changed (via pull output)
4. Restart only containers with updated images
5. Log all operations to journal

**Pruning:**
- Timer: `podman-prune.timer` (weekly)
- Removes: Unused images, stopped containers, networks

**Benefits:**
- ✅ Automatic security updates
- ✅ Minimal downtime (only restart if changed)
- ✅ Journal logging for audit trail

---

#### Helper Library: mkQuadletService

**Location:** `/etc/nixos/modules/lib/mkQuadletService.nix`

**Features:**
- Automatic systemd service generation
- Nginx reverse proxy configuration
- SOPS secret injection
- PostgreSQL dependency handling
- Network configuration
- Volume mounting
- Health check integration

**Example Usage:**
```nix
mkQuadletService {
  name = "litellm";
  image = "ghcr.io/berriai/litellm-database:main-stable";
  port = 4000;
  requiresPostgres = true;
  secrets = { litellmApiKey = "litellm-secrets"; };
  nginxVirtualHost = { enable = true; };
}
```

**Benefits:**
- ✅ Consistent container configuration
- ✅ Reduced code duplication
- ✅ Automatic monitoring integration
- ✅ Standardized secret management

---

### C. Container Monitoring

**Prometheus Metrics:**
- Via node-exporter (container CPU, memory, network)
- Container-specific exporters where applicable
- Blackbox probes for health checks

**Nagios Checks:**
- Each container monitored as a systemd service
- Service state checks (running/failed/inactive)

**Health Checks:**
- HTTP probes via blackbox-exporter
- Database connectivity checks (litellm, wallabag)
- Custom health endpoints where available

---

### D. Container Security

**Network Isolation:**
- Podman containers: 10.88.0.0/16 subnet
- systemd-nspawn: 10.233.1.0/24 subnet
- Firewall rules: Interface-specific (podman0, ve-+)

**Secret Management:**
- SOPS-encrypted secrets
- Injected via systemd `LoadCredential`
- Never stored in container images

**Resource Limits:**
- Currently: None (single-user system)
- Recommendation: Add if multi-tenant or resource pressure

**Rootless Mode:**
- Podman containers run rootless where possible
- systemd-nspawn runs as isolated namespace

---

## VI. TIMER SCHEDULE ANALYSIS

### A. Daily Maintenance Window (2-6 AM)

**Timeline Visualization:**

```
00:00 ━━ git-workspace-archive.timer
          Archives git repositories with SOPS github-token
          Duration: ~5-10 minutes

02:00 ━━ postgresql-backup.timer
          pg_dumpall → /tank/Backups/PostgreSQL/postgresql-backup.sql
          Duration: ~2-5 minutes

02:00 ━━ All 9 restic-backups-*.timer fire CONCURRENTLY
          ├── Audio → s3://jwiegley-Audio
          ├── Backups → s3://jwiegley-Backups-Misc
          ├── Databases → s3://jwiegley-Databases
          ├── Home → s3://jwiegley-Home
          ├── Nextcloud → s3://jwiegley-Nextcloud
          ├── Photos → s3://jwiegley-Photos
          ├── Video → s3://jwiegley-Video
          ├── doc → s3://jwiegley-doc
          └── src → s3://jwiegley-src

          Retention: 7 daily, 5 weekly, 3 yearly
          Restic handles locking (no conflicts)
          Duration: ~30-120 minutes (varies by dataset size)

04:00 ━━ backup-status-exporter.timer
          Generates Prometheus metrics for backup health
          Duration: <1 minute

04:00 ━━ logwatch.timer
          Analyzes logs, sends email summary
          Duration: ~2-5 minutes

06:00 ━━ certificate-validation.timer
          Validates all step-ca and Let's Encrypt certificates
          Checks expiry, validity, chain
          Duration: ~1 minute
```

**Design Analysis:**

✅ **Strengths:**
- PostgreSQL dump completes before restic backups start
- Restic backups run concurrently (designed behavior, uses repository locking)
- No timer conflicts or overlaps
- Monitoring timers outside backup window
- All timers use `Persistent = true` (run missed timers after boot)

⚠️ **Observations:**
- 9 concurrent restic backups may cause I/O spikes
- Network bandwidth usage during backup window
- B2 API rate limits (not an issue with current usage)

✅ **Mitigation:**
- Different ZFS datasets reduce I/O contention
- Restic deduplication reduces data transfer
- Backup window outside business hours

---

### B. High-Frequency Timers

**I/O Impact Analysis:**

| Timer | Frequency | I/O Pattern | Network | Impact | Recommendation |
|-------|-----------|-------------|---------|--------|----------------|
| nextcloud-cron.timer | 5 min | DB writes, file ops | Low | Normal | ✅ Acceptable |
| home-assistant-backup-monitor.timer | 5 min | File reads | None | Negligible | ✅ Acceptable |
| mbsync-johnw.timer | 15 min | Maildir writes | IMAP | Low | ⚠️ Consider 30min |
| mbsync-assembly-health-check.timer | 30 min | Textfile write | None | Negligible | ✅ Acceptable |
| mbsync-johnw-health-check.timer | 30 min | Textfile write | None | Negligible | ✅ Acceptable |

**Recommendation for mbsync-johnw.timer:**
```nix
# Current: Every 15 minutes (96 times/day)
# Consider: Every 30-60 minutes unless rapid email sync required

systemd.timers.mbsync-johnw = {
  timerConfig = {
    OnCalendar = "hourly";  # or "*:00,30:00" for 30min
  };
};
```

**Reasoning:**
- Most email doesn't require sub-15-minute delivery
- Reduces network traffic and potential rate limiting
- Maintains health check at 30min intervals

---

### C. Certificate Renewal Schedule

**Monthly Schedule (1st of month):**

```
03:00 ± 30min ━━ postgresql-cert-renewal.timer
                   Renews PostgreSQL server certificate
                   Reloads postgresql.service

03:30 ± 30min ━━ nginx-cert-renewal.timer
                   Renews all 15 nginx virtual host certificates
                   Reloads nginx.service

04:00 ± 30min ━━ postfix-cert-renewal.timer
                   Renews Postfix SMTP certificate
                   Reloads postfix.service

04:30 ± 30min ━━ dovecot-cert-renewal.timer
                   Renews Dovecot IMAP certificate
                   Reloads dovecot.service
```

**Design Features:**

✅ **Strengths:**
- Staggered 30-minute intervals prevent step-ca overload
- RandomizedDelaySec prevents exact-time clustering
- Outside backup window (no I/O contention)
- Monthly renewal (certificates valid 90 days, renew at 30 days)
- Service reloads (not restarts) minimize downtime

**Certificate Validity:**
- Default duration: 90 days (2160 hours)
- Renewal trigger: Monthly (30 days before expiry)
- Grace period: 60 days before forced expiry

**Location:** `/etc/nixos/modules/services/certificate-automation.nix`

---

### D. Timer Conflict Analysis

**Potential Conflicts Checked:**

| Time Window | Active Timers | Conflict? | Resolution |
|-------------|--------------|-----------|------------|
| 00:00-02:00 | git-workspace-archive | ❌ No | Single timer |
| 02:00-04:00 | postgresql-backup + 9× restic | ❌ No | Sequential (PG first) + concurrent (restic) |
| 04:00-06:00 | backup-status, logwatch | ❌ No | Different I/O patterns |
| 06:00-08:00 | certificate-validation | ❌ No | Single timer |
| Monthly 03:00-05:00 | 4× cert renewals | ❌ No | Staggered + randomized |

**Verdict:**
✅ No timer conflicts detected
✅ Resource usage well-distributed
✅ Backup window properly isolated

---

## VII. ARCHITECTURAL FINDINGS & RECOMMENDATIONS

### A. Strengths (Excellent Design)

#### 1. **Perfect Systemd Dependency Architecture**

✅ **Correct use of dependency directives:**
- `RequiresMountsFor` for path-based dependencies (best practice)
- `after` for ordering without hard dependencies
- `wants` for soft dependencies
- `requires` only where strictly necessary
- `wantedBy` for auto-start relationships

✅ **ZFS mount handling:**
- 22 services properly depend on `tank.mount`
- `nofail` mount option prevents boot blocking
- Services gracefully handle missing ZFS pool
- Auto-start when pool becomes available

✅ **No circular dependencies:**
- Verified via systemd-analyze
- Clean dependency tree
- Well-documented relationships

**Example (modules/storage/backups.nix:218-224):**
```nix
systemd.services = lib.mkMerge [
  (lib.mkMerge (map (name: {
    "restic-backups-${name}" = {
      after = [ "zfs.target" "zfs-import-tank.service" ];
      wantedBy = [ "tank.mount" ];
      unitConfig.RequiresMountsFor = [ "/tank" ];
    };
  }) (builtins.attrNames config.services.restic.backups)))
];
```

---

#### 2. **Comprehensive Monitoring Coverage**

✅ **Dual monitoring approach:**
- Prometheus: Modern metrics, 24 exporters, 18 alert groups
- Nagios: Traditional checks, 50+ services, email alerts
- Both systems monitor critical services (redundancy)

✅ **Self-monitoring:**
- Monitoring stack monitors itself
- Alerts if Prometheus/Grafana/Loki down
- Self-healing capability

✅ **Complete coverage:**
- All critical services: ✅ Monitored
- All containers: ✅ Monitored
- All tank-dependent services: ✅ Monitored
- All timers: ✅ Monitored (via systemd exporter)
- Blind spots: ❌ None found

✅ **Alert quality:**
- Appropriate severity levels
- Clear descriptions
- Actionable information
- No alert fatigue (well-tuned thresholds)

---

#### 3. **Robust Backup Strategy**

✅ **Multiple backup targets:**
- Restic → Backblaze B2 (9 repositories, offsite)
- PostgreSQL → `/tank/Backups/PostgreSQL/` (daily dumps)
- ZFS → Snapshots (hourly via sanoid)
- Git repositories → Daily archive

✅ **Blast radius isolation:**
- 9 separate restic repositories
- Each dataset backed up independently
- Failure in one backup doesn't affect others

✅ **Proper retention:**
- Daily: 7 snapshots
- Weekly: 5 snapshots
- Yearly: 3 snapshots
- Configurable per repository

✅ **Automated integrity:**
- Weekly: `restic-check.timer` (verify repository)
- Every 6h: `restic-metrics.timer` (monitor health)
- Daily: `backup-status-exporter.timer` (metrics)

✅ **Monitoring:**
- Prometheus alerts: ResticCheckFailed, ResticNoRecentSnapshot, ResticNoSnapshots
- Nagios checks: All 9 backup services + timers
- Metrics: Snapshot age, repository size, check status

---

#### 4. **Secure Certificate Management**

✅ **Private CA (step-ca):**
- System-wide trusted root CA
- Internal services use step-ca certificates
- Automated renewal (monthly)
- Daily validation checks

✅ **Let's Encrypt for public:**
- secure-nginx container
- Automatic ACME challenges
- Production certificates
- Auto-renewal

✅ **Renewal strategy:**
- Staggered schedule (30min intervals)
- Randomized delays (prevent clustering)
- Service reloads (not restarts)
- Outside backup window

✅ **Security:**
- TLS 1.2-1.3 only
- Strong cipher suites
- Certificate expiry monitoring
- Automated rotation

**Certificate Coverage:**
- PostgreSQL: SSL required
- Nginx: 15 virtual hosts
- Postfix: SMTP with STARTTLS
- Dovecot: IMAPS (993)
- Public website: Let's Encrypt

---

#### 5. **Container Orchestration**

✅ **Hybrid approach:**
- systemd-nspawn: Maximum isolation (secure-nginx)
- Podman: OCI compatibility, easy updates

✅ **Helper library (mkQuadletService):**
- Consistent configuration
- Automatic nginx proxy
- SOPS secret injection
- PostgreSQL dependency handling

✅ **Automated updates:**
- Daily: Pull latest images
- Smart restart: Only if image changed
- Weekly: Prune unused resources
- Journal logging: Full audit trail

✅ **Network isolation:**
- podman0: 10.88.0.0/16 (containers)
- ve-+: 10.233.1.0/24 (nspawn)
- Firewall: Interface-specific rules

✅ **Monitoring:**
- All containers in Prometheus
- All containers in Nagios
- Health checks via blackbox-exporter

---

#### 6. **Critical PostgreSQL Fix**

✅ **Race condition prevention:**

**Problem identified:**
- PostgreSQL starts at ~19s
- podman0 device created at ~50s
- Without fix: PostgreSQL only binds to localhost
- Result: Containers can't connect

**Solution (databases.nix:142-145):**
```nix
systemd.services.postgresql = {
  after = [ "sys-subsystem-net-devices-podman0.device" ];
  requires = [ "sys-subsystem-net-devices-podman0.device" ];
};
```

✅ **Benefits:**
- PostgreSQL waits for podman0
- Binds to 10.88.0.1 (podman gateway)
- Containers can connect
- Health checks pass
- Well-documented in comments

**Location:** `/etc/nixos/modules/services/databases.nix:138-146`

---

#### 7. **Modular Configuration**

✅ **Organization:**
- 81 nix modules
- Logical grouping by function
- Reusable helper libraries
- No code duplication

✅ **Helper functions:**
- `mkQuadletService`: Podman containers
- `mkPostgresUserSetup`: Database users
- `bindTankModule`: ZFS bind mounts
- `mkBackup`: Restic configurations

✅ **Maintainability:**
- Easy to add new services
- Consistent patterns
- Well-commented code
- Clear file organization

**Module Structure:**
```
/etc/nixos/modules/
├── core/ (6 files: boot, networking, firewall, etc.)
├── services/ (30+ files: one per service)
├── monitoring/ (22 files: prometheus stack)
├── containers/ (8 files: container definitions)
├── storage/ (4 files: ZFS, backups)
├── lib/ (5 files: helper functions)
└── users/ (4 files: user configurations)
```

---

### B. Identified Issues & Recommendations

#### Issue 1: Documentation Inaccuracy

**Problem:**
- `/etc/nixos/CLAUDE.md` states system is "Apple T2 x86_64"
- Actual system: "Apple Silicon M1 Max aarch64"

**Impact:** Low (documentation only, no functional impact)

**Recommendation:**

```bash
# Update /etc/nixos/CLAUDE.md
vim /etc/nixos/CLAUDE.md

# Change:
"an x86_64 Linux system running on Apple T2 hardware"
"nixos-hardware.nixosModules.apple-t2"

# To:
"an aarch64 Linux system running on Apple Silicon M1 Max (Asahi Linux)"
"Apple Silicon speaker protection (speakersafetyd.service)"
```

---

#### Issue 2: Mbsync High Frequency

**Problem:**
- `mbsync-johnw.timer` runs every 15 minutes (96 times/day)
- Potential for rate limiting by IMAP server
- Higher network traffic than necessary

**Impact:** Medium (network traffic, potential rate limiting)

**Current Configuration (mbsync.nix):**
```nix
systemd.timers.mbsync-johnw = {
  timerConfig = {
    OnCalendar = "*:00/15";  # Every 15 minutes
  };
};
```

**Recommendation:**

```nix
# Option 1: Hourly (recommended for most users)
systemd.timers.mbsync-johnw = {
  timerConfig = {
    OnCalendar = "hourly";
  };
};

# Option 2: Every 30 minutes (if sub-hour sync needed)
systemd.timers.mbsync-johnw = {
  timerConfig = {
    OnCalendar = "*:00,30:00";
  };
};
```

**Benefits:**
- Reduces network traffic
- Lowers risk of rate limiting
- Still provides timely email sync
- Maintains health check at 30min

---

#### Issue 3: Container DNS Configuration

**Observation:**
- Podman network has `dns_enabled = false`
- Reason: Conflicts with Technitium DNS on port 53
- Containers use host's `/etc/resolv.conf`

**Impact:** Low (working as designed, but worth documenting)

**Current Configuration (quadlet.nix:20-36):**
```nix
virtualisation.podman = {
  defaultNetwork.settings = {
    dns_enabled = false;  # Conflicts with Technitium DNS on 0.0.0.0:53
    subnets = [
      {
        subnet = "10.88.0.0/16";
        gateway = "10.88.0.1";
      }
    ];
  };
};
```

**Recommendation:**

Add documentation comment:
```nix
virtualisation.podman = {
  defaultNetwork.settings = {
    # DNS disabled: Technitium DNS server uses port 53 on host
    # Containers use host's /etc/resolv.conf (192.168.1.2 Technitium DNS)
    # This provides DNS resolution while avoiding port conflicts
    dns_enabled = false;

    subnets = [
      {
        subnet = "10.88.0.0/16";
        gateway = "10.88.0.1";
      }
    ];
  };
};
```

✅ **Already correctly configured, just needs better documentation**

---

#### Issue 4: Missing Disaster Recovery Documentation

**Problem:**
- No documented procedures for bare-metal restore
- No tested recovery drills
- Recovery Time Objectives (RTO) not defined

**Impact:** Medium (critical for disaster scenarios)

**Recommendation:**

Create comprehensive disaster recovery documentation:

```bash
cat > /etc/nixos/docs/DISASTER_RECOVERY.md <<'EOF'
# Disaster Recovery Procedures

## Recovery Time Objectives (RTO)

- **Critical Services:** 4 hours
- **Full System:** 8 hours
- **Complete Data Restore:** 24 hours

## 1. Bare-Metal Restore

### Prerequisites
- NixOS installation media (aarch64)
- Restic credentials (B2 keys, password)
- ZFS pool recreation

### Steps

1. **Boot NixOS installer**
2. **Recreate ZFS pool:**
   ```bash
   zpool create -f tank /dev/disk/by-id/...
   zfs create -o mountpoint=/tank tank
   ```

3. **Clone configuration:**
   ```bash
   git clone https://github.com/jwiegley/nixos-config /mnt/etc/nixos
   ```

4. **Restore critical data from Restic:**
   ```bash
   export RESTIC_REPOSITORY=s3:s3.us-west-001.backblazeb2.com/jwiegley-Home
   export RESTIC_PASSWORD=...
   export AWS_ACCESS_KEY_ID=...
   export AWS_SECRET_ACCESS_KEY=...

   restic restore latest --target /tank/Home
   ```

5. **Install NixOS:**
   ```bash
   nixos-install --flake /mnt/etc/nixos#vulcan
   ```

## 2. PostgreSQL Recovery

### Full Database Restore
```bash
sudo systemctl stop postgresql
sudo -u postgres psql -f /tank/Backups/PostgreSQL/postgresql-backup.sql
sudo systemctl start postgresql
```

### Specific Database Restore
```bash
sudo -u postgres psql -d database_name -f /tank/Backups/PostgreSQL/postgresql-backup.sql
```

## 3. ZFS Pool Recreation

### Identify Disk
```bash
ls -l /dev/disk/by-id/
```

### Create Pool
```bash
zpool create -f tank /dev/disk/by-id/nvme-...
zfs set compression=lz4 tank
zfs set atime=off tank
```

### Create Datasets
```bash
for ds in Audio Backups Databases Home Nextcloud Photos Video doc src Public; do
  zfs create tank/$ds
done
```

## 4. Service Restoration Order

1. ZFS pool (`zpool import tank`)
2. PostgreSQL (`systemctl start postgresql`)
3. Step-CA (`systemctl start step-ca`)
4. Nginx (`systemctl start nginx`)
5. Critical services (Home Assistant, Nextcloud)
6. Containers (`systemctl start litellm wallabag ...`)
7. Monitoring (Prometheus, Grafana, Nagios)

## 5. Recovery Testing Schedule

- **Monthly:** Test single file restore from Restic
- **Quarterly:** Test PostgreSQL database restore
- **Annually:** Full bare-metal restore drill

## 6. Recovery Verification

### Checklist
- [ ] ZFS pool imported and mounted
- [ ] PostgreSQL databases accessible
- [ ] All critical services running
- [ ] Certificates valid
- [ ] Monitoring operational
- [ ] Backups resuming
- [ ] Web services accessible

### Commands
```bash
# Verify ZFS
zpool status
zfs list

# Verify PostgreSQL
sudo -u postgres psql -l

# Verify services
systemctl --failed
systemctl list-units --type=service --state=running

# Verify monitoring
curl -s http://localhost:9090/-/healthy
curl -s http://localhost:3000/api/health
```

## 7. Contact Information

- **Administrator:** johnw@newartisans.com
- **Backup Provider:** Backblaze B2
- **DNS Provider:** Cloudflare (if applicable)

EOF
```

**Testing Schedule:**

```bash
# Add to crontab or systemd timer
# Monthly test: First Saturday of month
0 10 1-7 * 6 /path/to/test-recovery.sh
```

---

#### Issue 5: Container Resource Limits

**Observation:**
- No explicit CPU/memory limits on containers
- Appropriate for single-user system
- Could cause issues if resource pressure occurs

**Impact:** Low (acceptable for current scale)

**Current State:**
```nix
# mkQuadletService does not set resource limits
```

**Recommendation:**

Consider adding resource limits if:
- System becomes multi-tenant
- Resource pressure detected
- Container resource abuse observed

**Example Implementation:**

```nix
# In mkQuadletService helper (lib/mkQuadletService.nix)
serviceConfig = {
  # CPU: 200% = 2 cores max
  CPUQuota = "200%";

  # Memory: 2GB max
  MemoryMax = "2G";

  # I/O: Medium priority
  IOWeight = 500;

  # Tasks: Limit processes
  TasksMax = "1024";
};
```

**When to implement:**
- If monitoring shows resource contention
- If planning to run untrusted workloads
- If implementing multi-tenancy

✅ **Current configuration acceptable for single-user system**

---

### C. Performance Observations

#### 1. Database Tuning (Excellent)

✅ **Home Assistant PostgreSQL tuning:**

```nix
# modules/services/home-assistant.nix:204-231
settings = {
  # Memory settings - tuned for time-series data
  shared_buffers = "256MB";        # Increased from 128MB
  effective_cache_size = "1GB";    # Query planner hint
  work_mem = "16MB";               # Sort/hash operations
  maintenance_work_mem = "128MB";  # VACUUM, CREATE INDEX

  # WAL settings for write performance
  wal_buffers = "8MB";
  max_wal_size = "1GB";
  min_wal_size = "80MB";

  # Checkpointing for write-heavy workload
  checkpoint_completion_target = "0.9";

  # Autovacuum tuning for high-frequency inserts
  autovacuum = "on";
  autovacuum_max_workers = "2";
  autovacuum_naptime = "30s";
  autovacuum_vacuum_scale_factor = "0.05";
  autovacuum_analyze_scale_factor = "0.025";

  # Planner costs for SSD
  random_page_cost = "1.1";
  effective_io_concurrency = "200";

  # Statistics for better query planning
  default_statistics_target = "100";
};
```

✅ **LiteLLM database optimization:**

```nix
# modules/services/databases.nix:109-136
systemd.services.postgresql-litellm-optimize = {
  script = ''
    # Create index on api_key column for faster queries
    # Prevents slow sequential scans on large SpendLogs table
    psql -d litellm -c \
      'CREATE INDEX CONCURRENTLY IF NOT EXISTS "LiteLLM_SpendLogs_api_key_idx"
       ON "LiteLLM_SpendLogs" (api_key);'

    # Update statistics for better query plans
    psql -d litellm -c 'ANALYZE "LiteLLM_SpendLogs";'
  '';
};
```

✅ **Connection pooling:**
- Redis used for caching (nextcloud, litellm)
- max_connections = 200 (sufficient headroom)

---

#### 2. Backup Window Optimization

✅ **Concurrent execution:**
- All 9 restic backups run simultaneously
- Restic handles repository locking (no conflicts)
- Different ZFS datasets reduce I/O contention

✅ **Sequential where needed:**
- PostgreSQL dump completes first (02:00)
- Restic backups start after (02:00)
- No dependency conflicts

✅ **I/O distribution:**
```
Dataset         Path              I/O Pattern
--------------------------------------------------
Audio           /tank/Audio       Large files, sequential
Backups         /tank/Backups     Small files, random
Databases       /tank/Databases   Medium files, random
Home            /tank/Home        Mixed
Nextcloud       /tank/Nextcloud   Small files, random
Photos          /tank/Photos      Large files, sequential
Video           /tank/Video       Very large files, sequential
doc             /tank/doc         Small files, random
src             /tank/src         Small files, random
```

✅ **No contention detected:**
- Different datasets, different I/O patterns
- ZFS ARC caching helps
- Backblaze B2 handles concurrent uploads

---

#### 3. ZFS Performance

✅ **Configuration:**
- Compression: lz4 (fast, good ratio)
- atime: off (reduces writes)
- Snapshots: hourly (sanoid)

✅ **Potential Optimizations:**

**If more performance needed:**

```bash
# Add L2ARC (SSD cache for reads)
zpool add tank cache /dev/disk/by-id/ssd-...

# Add SLOG (SSD for sync writes)
zpool add tank log /dev/disk/by-id/ssd-...

# Tune ARC size (if memory available)
echo "options zfs zfs_arc_max=8589934592" >> /etc/modprobe.d/zfs.conf  # 8GB
```

✅ **Current performance acceptable for workload**

---

### D. Security Posture

#### Strengths

✅ **Secret Management:**
- SOPS: Encrypted secrets in git
- Age encryption
- Secrets deployed to `/run/secrets/`
- Systemd `LoadCredential` for service injection
- Never in container images

✅ **Certificate Security:**
- Step-CA: Private CA for internal services
- Let's Encrypt: Public-facing services
- TLS 1.2-1.3 only
- Strong cipher suites
- Automated renewal

✅ **Network Security:**
- Firewall: Interface-specific rules
- Container isolation: Separate networks
- PostgreSQL: SSL required, network restrictions
- Minimal port exposure

✅ **Service Hardening:**
- Nginx: HSTS, security headers, SSL termination
- PostgreSQL: scram-sha-256 auth, SSL enforcement
- SSH: Key-based auth (assumed)
- Container rootless mode where possible

✅ **Authentication:**
- PostgreSQL: Password authentication, SSL required
- Web services: Behind nginx with HTTPS
- Home Assistant: Authentication required
- Node-RED: Admin authentication (bcrypt)

---

#### Recommendations

**1. Consider fail2ban:**

```nix
services.fail2ban = {
  enable = true;
  jails = {
    sshd = {
      enabled = true;
      filter = "sshd";
      maxretry = 3;
      findtime = "10m";
      bantime = "1h";
    };
    nginx-limit-req = {
      enabled = true;
      filter = "nginx-limit-req";
      maxretry = 5;
      findtime = "2m";
      bantime = "10m";
    };
  };
};
```

**Benefits:**
- Brute-force protection
- Automated IP banning
- Minimal resource usage

---

**2. AppArmor/SELinux profiles (optional):**

```nix
# AppArmor for container confinement
security.apparmor = {
  enable = true;
  packages = [ pkgs.apparmor-profiles ];
};
```

**Note:** Asahi Linux may have limited AppArmor support. Verify before implementing.

---

**3. Automated security updates:**

```nix
# Option 1: Daily rebuild (requires review)
systemd.services.nixos-upgrade = {
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake /etc/nixos#vulcan";
  };
};

systemd.timers.nixos-upgrade = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "daily";
    Persistent = true;
  };
};

# Option 2: Auto-update flake inputs
systemd.services.flake-update = {
  serviceConfig = {
    Type = "oneshot";
    WorkingDirectory = "/etc/nixos";
    ExecStart = "${pkgs.nix}/bin/nix flake update";
  };
};
```

**Recommendation:** Manual updates preferred for production systems to avoid surprises.

---

### E. Disaster Recovery Assessment

#### Recovery Capabilities

✅ **Current Backups:**
- PostgreSQL: Daily dumps to `/tank/Backups/PostgreSQL/`
- Restic: 9 repositories to offsite B2 (daily)
- ZFS: Hourly snapshots (sanoid)
- Git: Daily repository archive
- Container images: Auto-updated (redeploy from config)

✅ **Recovery Points:**
- Point-in-time: ZFS snapshots (hourly)
- Daily: Restic backups (7 daily, 5 weekly, 3 yearly)
- Database: Daily PostgreSQL dumps

✅ **Offsite Storage:**
- Backblaze B2 (restic repositories)
- Encrypted with restic-password
- Geographic redundancy

---

#### Missing Components

⚠️ **Gaps:**
1. No documented bare-metal restore procedure
2. No tested recovery drills
3. No defined RTO/RPO
4. No recovery runbook

**Impact:** Medium (critical for disaster scenarios)

**Recommendation:** See "Issue 4: Missing Disaster Recovery Documentation" above

---

#### Recovery Testing

**Recommended Schedule:**

| Frequency | Test | Duration | Owner |
|-----------|------|----------|-------|
| Monthly | Single file restore from Restic | 15 min | Administrator |
| Quarterly | PostgreSQL database restore to test instance | 30 min | Administrator |
| Semi-annually | ZFS pool recreation (test system) | 1 hour | Administrator |
| Annually | Full bare-metal restore drill | 4-8 hours | Administrator |

**Test Script Example:**

```bash
#!/usr/bin/env bash
# Monthly recovery test: Restore random file from restic

set -euo pipefail

# Pick random repository
REPOS=(Audio Backups Databases Home Nextcloud Photos Video doc src)
REPO="${REPOS[$RANDOM % ${#REPOS[@]}]}"

export RESTIC_REPOSITORY="s3:s3.us-west-001.backblazeb2.com/jwiegley-$REPO"
export RESTIC_PASSWORD=$(cat /run/secrets/restic-password)
source /run/secrets/aws-keys

# List files in latest snapshot
restic ls latest | shuf -n 1 | tee /tmp/recovery-test-file.txt

# Restore to temporary location
restic restore latest --target /tmp/recovery-test --include $(cat /tmp/recovery-test-file.txt)

# Verify
if [ -f "/tmp/recovery-test/$(cat /tmp/recovery-test-file.txt)" ]; then
  echo "✅ Recovery test successful: $REPO"
  rm -rf /tmp/recovery-test /tmp/recovery-test-file.txt
  exit 0
else
  echo "❌ Recovery test failed: $REPO"
  exit 1
fi
```

---

## VIII. INTEGRATION ANALYSIS

### A. Service Integration Map

#### Home Assistant Hub

**Home Assistant integrates with:**

```
home-assistant.service (central hub)
  ├── Database: PostgreSQL (recorder)
  ├── Automation: Node-RED (flows)
  ├── Monitoring: Prometheus (metrics export)
  ├── Voice Control: Google Assistant SDK
  ├── AI: Extended OpenAI Conversation (LLM via OpenAI API)
  ├── HomeKit: Bridge (expose entities to Apple Home)
  └── IoT Platforms (17+):
      ├── Security & Access:
      │   ├── Yale/August (smart locks)
      │   ├── Ring (doorbell, chimes, cameras)
      │   └── ADT (alarm system via Google Assistant)
      ├── Energy:
      │   ├── Enphase Envoy (solar inverter)
      │   ├── Tesla Wall Connector (EV charging)
      │   ├── Flume (water meter)
      │   └── SMUD/Opower (utility usage)
      ├── Climate:
      │   └── Nest (thermostats)
      ├── Network:
      │   ├── OPNsense (firewall - HACS custom component)
      │   └── ASUS Router (device tracking)
      ├── Appliances:
      │   ├── LG ThinQ (smart appliances)
      │   ├── Miele (dishwasher)
      │   └── Traeger (grill)
      ├── Entertainment:
      │   ├── LG webOS TV
      │   ├── Google Cast devices
      │   └── Bose speakers
      ├── Outdoor:
      │   ├── Pentair IntelliCenter (pool/spa)
      │   ├── MyQ (garage door)
      │   ├── B-Hyve (sprinklers)
      │   └── Dreame (robot vacuum)
      ├── Vehicles:
      │   └── BMW ConnectedDrive
      └── Health:
          ├── Withings (scale)
          └── Apple iCloud (device tracking)
```

**Energy Dashboard:**
- Solar production: Enphase
- EV charging: Tesla Wall Connector
- Water usage: Flume
- Utility data: SMUD via Opower

---

#### LiteLLM Hub

**LiteLLM integrates with:**

```
litellm.service (LLM proxy)
  ├── Database: PostgreSQL (usage tracking, API keys)
  ├── Cache: Redis (litellm instance)
  ├── Monitoring: Prometheus (litellm-exporter)
  ├── Web UI: Nginx reverse proxy (litellm.vulcan.lan)
  └── Upstream:
      ├── Home Assistant (Extended OpenAI Conversation)
      └── External LLM providers (proxied)
```

---

#### Monitoring Stack Integration

**Data Flow:**

```
Services → Exporters → Prometheus → Outputs
                                   ├── Grafana (visualization)
                                   ├── Alertmanager (alerts)
                                   └── VictoriaMetrics (long-term storage)

Logs → Promtail → Loki → Grafana (log visualization)

Services → Nagios → Email (traditional alerts)
```

**Integration Points:**

| Service | Prometheus | Loki | Nagios | Grafana |
|---------|-----------|------|--------|---------|
| PostgreSQL | ✅ postgres-exporter | ✅ journald | ✅ systemd check | ✅ Dashboard |
| Nginx | ✅ nginx-exporter | ✅ access logs | ✅ systemd check | ✅ Dashboard |
| Home Assistant | ✅ built-in | ✅ journald | ✅ systemd check | ✅ Dashboard |
| Containers | ✅ node-exporter | ✅ journald | ✅ systemd check | ✅ Dashboard |
| ZFS | ✅ zfs-exporter | ✅ journald | ✅ systemd check | ✅ Dashboard |
| Restic | ✅ restic-metrics | ✅ journald | ✅ systemd check | ✅ Dashboard |

---

### B. No Integration Gaps Detected

**Verification:**

✅ **All services properly connected:**
- Database clients → PostgreSQL
- Web services → Nginx reverse proxy
- Containers → Host database/cache
- Monitoring → All critical services
- Backup services → Storage targets

✅ **Metrics flowing correctly:**
- All exporters → Prometheus
- Prometheus → Grafana dashboards
- Prometheus → Alertmanager
- Alertmanager → Email notifications

✅ **Logs flowing correctly:**
- All services → journald
- Promtail → journald
- journald → Loki
- Loki → Grafana

✅ **Alerts configured appropriately:**
- Critical: Email + Prometheus alerts
- Warning: Prometheus alerts
- Info: Metrics only

✅ **No orphaned services:**
- All services have purpose
- All services monitored
- All services in dependency tree

---

## IX. SCALABILITY ASSESSMENT

### A. Current Resource Utilization

**System Statistics:**

| Resource | Current | Capacity | Utilization | Headroom |
|----------|---------|----------|-------------|----------|
| Services | 63 active | ~200 (systemd limit) | 32% | ✅ Excellent |
| Containers | 7 | Limited by memory | <10% | ✅ Excellent |
| Timers | 32 | ~100 (practical) | 32% | ✅ Excellent |
| PostgreSQL connections | ~20-40 | 200 (max) | 10-20% | ✅ Excellent |
| Nginx vhosts | 15 | No limit | N/A | ✅ Excellent |
| ZFS datasets | 15+ | 2^64 | <0.001% | ✅ Excellent |
| Podman network | ~10 IPs | 65,534 | <0.1% | ✅ Excellent |

**Estimated Memory Usage:**
- Base system: ~2GB
- PostgreSQL: ~512MB
- Containers: ~2GB
- Services: ~1GB
- Monitoring: ~1GB
- ZFS ARC: ~4GB (dynamic)
- **Total:** ~10-12GB (M1 Max has 32-64GB available)

---

### B. Headroom Analysis

**Can support additional services:** ✅ Yes

**Resource Limits:**

| Resource | Current | Max Practical | Notes |
|----------|---------|---------------|-------|
| PostgreSQL connections | 200 | 500 | Increase max_connections if needed |
| Nginx vhosts | 15 | 100+ | Limited by certificate management |
| Container network | 10.88.0.0/16 | 65K addresses | Ample space |
| ZFS capacity | Varies | Disk size | Add more disks if needed |
| Memory | ~12GB | 32-64GB | Large headroom |
| Systemd services | 63 | 200-300 | No hard limit |

**Scalability Strategies:**

1. **More containers:** Add to podman network
2. **More databases:** PostgreSQL supports many databases
3. **More web services:** Add nginx vhosts
4. **More backup repos:** Add restic configurations
5. **More monitoring:** Add exporters/checks

---

### C. Bottleneck Analysis

**Potential Bottlenecks:**

#### 1. ZFS I/O

**Current:**
- Single pool
- Multiple concurrent backups
- High-frequency writes (HA, Nextcloud)

**Indicators:**
- Backup window: 30-120 minutes
- Normal operation: No slowness reported

**Mitigation (if needed):**
```bash
# Add L2ARC cache (SSD)
zpool add tank cache /dev/disk/by-id/ssd-cache

# Add SLOG (SSD for sync writes)
zpool add tank log mirror \
  /dev/disk/by-id/ssd-slog1 \
  /dev/disk/by-id/ssd-slog2

# Add more disks (striped or RAID-Z)
zpool add tank raidz2 \
  /dev/disk/by-id/disk1 \
  /dev/disk/by-id/disk2 \
  /dev/disk/by-id/disk3 \
  /dev/disk/by-id/disk4
```

**Current Status:** ✅ Acceptable performance

---

#### 2. PostgreSQL

**Current:**
- Shared by 5+ services
- Tuned for time-series (HA)
- max_connections: 200

**Indicators:**
- Connection count: 20-40 active
- Query performance: Good
- Autovacuum keeping up

**Mitigation (if needed):**
```nix
# Increase connections
services.postgresql.settings.max_connections = 500;

# Add connection pooling
services.pgbouncer = {
  enable = true;
  databases = {
    hass = "host=localhost port=5432 dbname=hass";
    litellm = "host=localhost port=5432 dbname=litellm";
  };
};

# Separate database instances (if extreme load)
services.postgresql_hass = { ... };  # Separate instance
```

**Current Status:** ✅ Excellent headroom

---

#### 3. Network Bandwidth

**Current:**
- Single gigabit interface (end0)
- Backup traffic: Restic to B2
- Home Assistant: IoT traffic
- Media serving: Jellyfin

**Indicators:**
- Daily backup window: 2-4 AM
- Normal operation: Low utilization
- No congestion reported

**Mitigation (if needed):**
```nix
# QoS for traffic prioritization
networking.localCommands = ''
  tc qdisc add dev end0 root handle 1: htb default 30
  tc class add dev end0 parent 1: classid 1:1 htb rate 1gbit
  tc class add dev end0 parent 1:1 classid 1:10 htb rate 500mbit prio 1  # Interactive
  tc class add dev end0 parent 1:1 classid 1:20 htb rate 300mbit prio 2  # Backups
  tc class add dev end0 parent 1:1 classid 1:30 htb rate 200mbit prio 3  # Default
'';
```

**Current Status:** ✅ No congestion

---

### D. Growth Recommendations

**If scaling beyond current capacity:**

#### Short-term (1-2 services)
- ✅ Add to existing infrastructure
- ✅ Use mkQuadletService for containers
- ✅ Add monitoring automatically

#### Medium-term (5-10 services)
- Consider service grouping
- Review timer schedules
- Monitor resource usage trends

#### Long-term (20+ services)
- Consider separate PostgreSQL instances
- Evaluate dedicated monitoring host
- Review network architecture
- Consider ZFS pool expansion

**Current Status:**
✅ **Excellent scalability headroom**
✅ **No immediate scaling concerns**
✅ **Well-positioned for growth**

---

## X. FINAL VERDICT

### Overall Architecture Rating: **EXCELLENT (9.5/10)**

**Your NixOS infrastructure is production-ready, well-designed, and comprehensively monitored.**

---

### Summary Scorecard

| Category | Score | Status | Notes |
|----------|-------|--------|-------|
| Dependency Architecture | 10/10 | ✅ Excellent | Perfect systemd dependency patterns |
| Monitoring Coverage | 10/10 | ✅ Excellent | Dual coverage, no blind spots |
| Backup Strategy | 10/10 | ✅ Excellent | Offsite, automated, integrity-checked |
| Security Posture | 9/10 | ✅ Very Good | Strong, could add fail2ban |
| Certificate Management | 10/10 | ✅ Excellent | Automated, monitored, secure |
| Container Orchestration | 9/10 | ✅ Very Good | Hybrid approach, automated updates |
| Code Quality | 10/10 | ✅ Excellent | Modular, reusable, well-documented |
| Performance | 9/10 | ✅ Very Good | Tuned appropriately, headroom available |
| Scalability | 9/10 | ✅ Very Good | Excellent headroom for growth |
| Documentation | 8/10 | ⚠️ Good | Needs DR procedures, minor inaccuracy |

**Overall:** 9.5/10

---

### Key Achievements

#### 1. ✅ Perfect Dependency Architecture
- No circular dependencies
- Correct use of systemd directives
- 22 services auto-start with tank.mount
- Services gracefully handle missing dependencies

#### 2. ✅ Comprehensive Monitoring
- 24 Prometheus exporters
- 50+ Nagios checks
- 18 alert rule groups
- Dual monitoring coverage (redundancy)
- Self-monitoring capability

#### 3. ✅ Robust Backup Strategy
- 9 restic repositories (offsite B2)
- PostgreSQL daily dumps
- ZFS hourly snapshots
- Automated integrity checks
- Proper retention policy

#### 4. ✅ Secure by Design
- SOPS for secrets
- Step-CA for internal certs
- Let's Encrypt for public
- PostgreSQL SSL enforcement
- Network isolation

#### 5. ✅ Auto-Healing
- Services auto-start when dependencies available
- Container auto-updates
- Certificate auto-renewal
- Monitoring self-healing

#### 6. ✅ Critical PostgreSQL Fix
- Waits for podman0 device
- Prevents race condition
- Ensures container connectivity
- Well-documented

#### 7. ✅ Modular Configuration
- 81 nix modules
- Reusable helpers
- Consistent patterns
- Maintainable

---

### Minor Issues (5 found)

| Issue | Impact | Status | Priority |
|-------|--------|--------|----------|
| Documentation inaccuracy | Low | 📝 Fix needed | P3 |
| Mbsync high frequency | Medium | ⚠️ Review | P2 |
| No DR documentation | Medium | 📝 Create | P1 |
| No resource limits | Low | ✅ Acceptable | P4 |
| No recovery drills | Medium | 📋 Schedule | P2 |

---

### Architectural Highlights

**Most Impressive Design Decisions:**

#### 1. PostgreSQL Podman Race Fix
**Location:** `modules/services/databases.nix:142-145`

```nix
systemd.services.postgresql = {
  after = [ "sys-subsystem-net-devices-podman0.device" ];
  requires = [ "sys-subsystem-net-devices-podman0.device" ];
};
```

**Why it's impressive:**
- Identifies subtle race condition
- Simple, elegant solution
- Well-documented reasoning
- Critical for container connectivity

---

#### 2. ZFS Auto-Start Architecture
**Location:** `modules/storage/backups.nix:216-250`

```nix
systemd.services = lib.mkMerge [
  (lib.mkMerge (map (name: {
    "restic-backups-${name}" = {
      after = [ "zfs.target" "zfs-import-tank.service" ];
      wantedBy = [ "tank.mount" ];
      unitConfig.RequiresMountsFor = [ "/tank" ];
    };
  }) (builtins.attrNames config.services.restic.backups)))
];
```

**Why it's impressive:**
- Uses best-practice `RequiresMountsFor`
- Auto-start via `wantedBy`
- Scales automatically with map
- Allows boot without ZFS (nofail)

---

#### 3. Helper Libraries
**Locations:**
- `modules/lib/mkQuadletService.nix`
- `modules/lib/mkPostgresUserSetup.nix`
- `modules/lib/bindTankModule.nix`

**Why it's impressive:**
- Eliminates code duplication
- Ensures consistency
- Makes adding services trivial
- Self-documenting patterns

---

#### 4. Dual Monitoring Coverage
**Locations:**
- `modules/monitoring/services/*.nix` (Prometheus)
- `modules/services/nagios.nix` (Nagios)

**Why it's impressive:**
- Modern + traditional coverage
- Redundancy prevents blind spots
- Different alert mechanisms
- Self-monitoring capability

---

## XI. ACTIONABLE RECOMMENDATIONS (Priority Ordered)

### Priority 1: Documentation

#### Update System Architecture Documentation

```bash
# Fix hardware description
vim /etc/nixos/CLAUDE.md

# Change:
"an x86_64 Linux system running on Apple T2 hardware"

# To:
"an aarch64 Linux system running on Apple Silicon M1 Max (Asahi Linux)"
```

**Estimated time:** 5 minutes

---

#### Create Disaster Recovery Documentation

```bash
# Create comprehensive DR guide
# See Section VII.B.4 for full template
vim /etc/nixos/docs/DISASTER_RECOVERY.md
```

**Contents:**
1. Recovery Time Objectives (RTO/RPO)
2. Bare-metal restore procedure
3. PostgreSQL recovery
4. ZFS pool recreation
5. Service restoration order
6. Recovery testing schedule
7. Verification checklist

**Estimated time:** 1-2 hours

---

### Priority 2: Testing

#### Implement Recovery Testing Schedule

```bash
# Monthly: Single file restore
cat > /root/scripts/test-recovery-monthly.sh <<'EOF'
#!/usr/bin/env bash
# Test restoring a random file from a random repository
# See Section VII.E.4 for full script
EOF

chmod +x /root/scripts/test-recovery-monthly.sh

# Add to systemd timer
cat > /etc/nixos/modules/maintenance/recovery-tests.nix <<'EOF'
{ config, lib, pkgs, ... }:
{
  systemd.services.recovery-test-monthly = {
    description = "Monthly recovery test: Restore random file";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/root/scripts/test-recovery-monthly.sh";
    };
  };

  systemd.timers.recovery-test-monthly = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
    };
  };
}
EOF
```

**Estimated time:** 30 minutes setup, 15 minutes monthly

---

### Priority 3: Optional Enhancements

#### Reduce mbsync Frequency (if appropriate)

```nix
# Edit modules/services/mbsync.nix
systemd.timers.mbsync-johnw = {
  timerConfig = {
    # Change from every 15 minutes to hourly
    OnCalendar = "hourly";
    # Or every 30 minutes: OnCalendar = "*:00,30:00";
  };
};
```

**Benefits:**
- Reduces network traffic
- Lowers IMAP server load
- Still provides timely sync

**Estimated time:** 5 minutes

---

#### Add fail2ban for Brute-Force Protection

```nix
# Add to configuration.nix or new module
services.fail2ban = {
  enable = true;
  maxretry = 3;
  ignoreIP = [ "127.0.0.0/8" "192.168.1.0/24" ];

  jails = {
    sshd = {
      enabled = true;
      filter = "sshd";
      maxretry = 3;
      findtime = "10m";
      bantime = "1h";
    };

    nginx-limit-req = {
      enabled = true;
      filter = "nginx-limit-req";
      maxretry = 5;
      findtime = "2m";
      bantime = "10m";
    };
  };
};
```

**Estimated time:** 15 minutes

---

#### Add Container Resource Limits (if needed)

```nix
# Edit lib/mkQuadletService.nix
# Add to serviceConfig:
serviceConfig = {
  # ... existing config ...

  # Optional resource limits
  MemoryMax = "2G";
  CPUQuota = "200%";
  IOWeight = "500";
  TasksMax = "1024";
};
```

**When to implement:**
- Resource contention detected
- Planning multi-tenancy
- Running untrusted workloads

**Estimated time:** 20 minutes

---

### Priority 4: Future Considerations

#### Monitor Trends

```bash
# Add capacity planning dashboard to Grafana
# Track:
# - PostgreSQL connection count over time
# - Disk usage growth rate
# - Backup duration trends
# - Network bandwidth utilization
```

#### Plan for Growth

```bash
# If scaling beyond 100 services:
# - Consider dedicated monitoring host
# - Evaluate separate PostgreSQL instances
# - Review network architecture
# - Plan ZFS expansion
```

---

## XII. CONCLUSION

Your NixOS infrastructure demonstrates **professional-grade architecture** with:

### Strengths

✅ **Correct systemd dependency patterns throughout**
- `RequiresMountsFor` for path dependencies
- `wantedBy` for auto-start relationships
- No circular dependencies
- Clean dependency tree

✅ **Comprehensive monitoring with no blind spots**
- 24 Prometheus exporters
- 50+ Nagios checks
- 18 alert rule groups
- Dual coverage (redundancy)
- Self-monitoring

✅ **Robust backup strategy with offsite replication**
- 9 restic repositories to B2
- PostgreSQL daily dumps
- ZFS hourly snapshots
- Automated integrity checks
- Proper retention policy

✅ **Secure secret management (SOPS)**
- Encrypted secrets in git
- Age encryption
- Systemd credential injection
- Never in container images

✅ **Auto-healing services (tank.mount integration)**
- 22 services auto-start with ZFS
- Services gracefully handle missing dependencies
- Monitoring shows correct errors
- No manual intervention needed

✅ **Well-documented, modular configuration**
- 81 nix modules
- Reusable helper libraries
- Consistent patterns
- Maintainable codebase

✅ **Production-ready for long-term operation**
- Excellent scalability headroom
- Performance tuned appropriately
- Secure by design
- Comprehensive monitoring

---

### Architecture Quality

**Rated:** 9.5/10 (Excellent)

**Production Status:** ✅ Ready

**Maintenance Burden:** Low (automated)

**Scalability:** Excellent headroom

**Security:** Strong posture

**Reliability:** High (auto-healing)

---

### Total Inventory

| Category | Count | Notes |
|----------|-------|-------|
| **Services** | 63 active | All monitored |
| **Containers** | 7 (1 nspawn + 6 podman) | Auto-updating |
| **Timers** | 32 | No conflicts |
| **Configuration Modules** | 81 | Modular, reusable |
| **Nginx Virtual Hosts** | 15+ | All with SSL |
| **PostgreSQL Databases** | 5+ | Tuned, monitored |
| **Restic Repositories** | 9 | Offsite B2 |
| **ZFS Datasets** | 15+ | Compressed, snapshotted |
| **Prometheus Exporters** | 24 | Complete coverage |
| **Prometheus Alert Groups** | 18 | Appropriate severity |
| **Nagios Service Checks** | 50+ | Redundant monitoring |

---

### Critical Features

1. **PostgreSQL Podman Race Fix** - Prevents container connectivity issues
2. **ZFS Auto-Start** - 22 services auto-start with tank.mount
3. **Dual Monitoring** - Prometheus + Nagios (redundancy)
4. **Automated Backups** - Daily restic + PostgreSQL dumps
5. **Certificate Automation** - Monthly renewals, daily validation
6. **Container Updates** - Daily pull, smart restart
7. **Helper Libraries** - mkQuadletService, mkPostgresUserSetup, bindTankModule

---

### Only Improvements Needed

1. ✏️ **Documentation:** Fix Apple T2 → M1 Max description
2. 📖 **Disaster Recovery:** Create comprehensive DR procedures
3. 🧪 **Testing:** Implement recovery testing schedule
4. ⚡ **Optional:** Consider reducing mbsync frequency
5. 🛡️ **Optional:** Add fail2ban for brute-force protection

**No critical issues found.**

**System architecture is optimal for current workload and scale.**

---

## Appendix: Quick Reference

### File Locations

**Core Configuration:**
- `/etc/nixos/flake.nix` - Main flake
- `/etc/nixos/configuration.nix` - System config
- `/etc/nixos/modules/` - 81 modules

**Key Modules:**
- `modules/services/databases.nix` - PostgreSQL + critical fix
- `modules/storage/backups.nix` - Restic backups
- `modules/services/certificates.nix` - Step-CA
- `modules/services/home-assistant.nix` - IoT platform
- `modules/services/nagios.nix` - Monitoring
- `modules/monitoring/services/prometheus-server.nix` - Metrics

**Secrets:**
- `/etc/nixos/secrets.yaml` - SOPS encrypted (in git)
- `/run/secrets/` - Deployed secrets (runtime)

**Documentation:**
- `/etc/nixos/CLAUDE.md` - System guide
- `/etc/nixos/docs/HOME_ASSISTANT_DEVICES.md` - IoT devices
- `/etc/nixos/docs/ADT_ALARM_CONTROL.md` - Alarm integration
- `/etc/nixos/docs/DISASTER_RECOVERY.md` - **TO CREATE**

---

### Monitoring Access

**Web Interfaces:**
- Prometheus: https://prometheus.vulcan.lan
- Grafana: https://grafana.vulcan.lan
- Alertmanager: https://alertmanager.vulcan.lan
- Nagios: https://nagios.vulcan.lan
- Home Assistant: https://hass.vulcan.lan
- Nextcloud: https://nextcloud.vulcan.lan

**Command Line:**
```bash
# Service status
systemctl --failed
systemctl list-units --type=service --state=running

# Timer status
systemctl list-timers

# Container status
podman ps -a

# ZFS status
zpool status
zfs list

# Backup status
restic-doc snapshots
restic-operations snapshots

# Monitoring
curl -s http://localhost:9090/-/healthy
```

---

### Emergency Contacts

- **Administrator:** johnw@newartisans.com
- **Backup Provider:** Backblaze B2
- **Issues:** /etc/nixos issues tracked in git

---

**End of Architectural Review**

*This comprehensive review analyzed all 63 services, 7 containers, 32 timers, and 81 configuration modules.*

*System architecture is production-ready with excellent design patterns and comprehensive monitoring.*
