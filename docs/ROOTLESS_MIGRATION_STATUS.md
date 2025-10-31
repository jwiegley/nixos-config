# Rootless Podman Migration - Final Status Report

## Successfully Converted to Rootless (10 services)

### container-db (6 services)
- ✅ metabase - PostgreSQL-backed BI platform
- ✅ wallabag - PostgreSQL-backed read-it-later service  
- ✅ teable - PostgreSQL-backed no-code database
- ✅ nocobase - PostgreSQL-backed no-code platform
- ✅ vanna - AI-powered SQL query generator (custom image)
- ✅ litellm - LLM proxy with PostgreSQL + Redis

### container-web (1 service)
- ✅ silly-tavern - LLM chat interface

### container-monitor (2 services)
- ✅ opnsense-exporter - Prometheus exporter for OPNsense
- ✅ technitium-dns-exporter - Prometheus exporter for Technitium DNS (custom image)

### container-misc (1 service)
- ✅ speedtest - Network speed testing service

## Remaining as Root (2 Pods = 6 containers)

### Documented Limitation: quadlet-nix Pods don't support rootless
- ❌ budget-board Pod (server + client + infra)
- ❌ changedetection Pod (app + exporter + infra)

**Reason:** Rootless Pods can't write pidfiles to /run/. Would require:
- User-mode systemd services, OR  
- Upstream quadlet-nix support for rootless Pods, OR
- Restructuring to eliminate Pod architecture

## Key Technical Solutions

### 1. Networking (slirp4netns)
- All rootless containers use: `networks = [ "slirp4netns:allow_host_loopback=true" ]`
- Enables localhost access for PostgreSQL/Redis/services on host

### 2. PostgreSQL Access
- Automatic override in mkQuadletService: `POSTGRES_HOST = "127.0.0.1"` for rootless
- pg_isready checks updated to use 127.0.0.1
- All database services connect via localhost

### 3. Redis Integration (litellm)
- Changed redis bind from 10.88.0.1 → 127.0.0.1
- Rootless containers access via host.containers.internal
- Works with slirp4netns allow_host_loopback

### 4. Secret Sharing (technitium-dns-exporter)
- Created shared group: `technitium-readers`
- Both container-monitor and dns-query-exporter in group
- Secret owned by: dns-query-exporter:technitium-readers mode 0440

### 5. Custom Images (vanna, technitium-dns-exporter)
- Images copied from root store → rootless user store
- Added `pull = "never"` to prevent registry lookups
- Works for localhost/custom:latest images

### 6. Directory Ownership
- All volume directories owned by container user
- tmpfilesRules use container-user:container-user
- Existing directories fixed with chown before conversion

## Performance & Security Benefits

### Security Improvements
- 10 containers no longer run as root
- User namespace isolation active (autoSubUidGidRange)
- Reduced attack surface for containerized services
- Container escapes limited to user privileges

### Resource Management
- Each container user has dedicated UID/GID range (65536 UIDs)
- Separate /run/user/UID/ directories for runtime files
- Improved cgroup isolation per container user

## Monitoring Status
- ✅ All exporters publish to 127.0.0.1
- ✅ Prometheus scraping from localhost works
- ✅ Grafana dashboards functional
- ✅ Service health checks operational

## Files Modified
- modules/lib/mkQuadletService.nix: Added rootless support
- modules/users/container-users.nix: Added container users and groups
- modules/containers/*-quadlet.nix: Added containerUser parameter (10 files)
- modules/monitoring/services/dns-query-logs.nix: Shared group for secrets
- modules/containers/quadlet.nix: Added slirp4netns package

## Pattern Established for Future Services

To convert a service to rootless:
1. Add `containerUser = "container-{db|web|monitor|misc}"`
2. Update tmpfilesRules to use container user ownership
3. Fix existing directory ownership: `chown -R user:user /path`
4. For custom images: Add `extraContainerConfig = { pull = "never"; }`
5. For shared secrets: Use shared group instead of root group
6. Rebuild and verify

**Total Migration:** 10/12 non-Pod services running rootless (83% success rate)
