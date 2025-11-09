# Container User Migration to Dedicated Accounts

## Overview

This document describes the migration from shared container users (`container-db`, `container-web`, `container-monitor`, `container-misc`) to dedicated per-service user accounts for improved security isolation.

**Status**: Configuration changes complete, awaiting user activation

## Security Benefits

### Before Migration (Shared Users)
- **container-db**: 7 services (litellm, metabase, mindsdb, nocobase, vanna, wallabag, teable)
- **container-web**: 1 service (silly-tavern)
- **container-monitor**: 2 services (opnsense-exporter, technitium-dns-exporter)
- **container-misc**: 2 services (openspeedtest, paperless-ai)

**Security Risk**: If one service is compromised, attacker gains access to all services under that shared user.

### After Migration (Dedicated Users)
Each service runs under its own dedicated user account:
- **litellm** → litellm user
- **metabase** → metabase user
- **mindsdb** → mindsdb user
- **nocobase** → nocobase user
- **vanna** → vanna user
- **wallabag** → wallabag user
- **teable** → teable user
- **silly-tavern** → sillytavern user (no hyphen in username)
- **opnsense-exporter** → opnsense-exporter user
- **technitium-dns-exporter** → technitium-dns-exporter user
- **openspeedtest** → openspeedtest user
- **paperless-ai** → paperless-ai user

**Security Improvement**: Complete isolation between services. Compromised service cannot access data from other services.

## Containers NOT Affected

The following containers run in pods as root and are **excluded** from this migration:
- **monica pod**: monica-app, mariadb
- **budget-board pod**: budget-board-server, budget-board-client

These remain unchanged because they are pod members, which require different handling.

## Configuration Changes Made

### New Files Created

1. **/etc/nixos/modules/users/container-users-dedicated.nix**
   - Defines 12 dedicated system users (one per service)
   - Each user has:
     - Own home directory: `/var/lib/containers/<service-name>`
     - Own group
     - Own secrets directory: `/run/secrets-<service-name>/`
     - Auto-allocated UID/GID ranges for namespaces
     - Linger enabled for systemd user services

2. **/etc/nixos/modules/users/home-manager/container-users-dedicated.nix**
   - Home-manager configurations for all dedicated users
   - Provides minimal environment for container operations

3. **/etc/nixos/scripts/migrate-container-users.sh**
   - Automated migration script for data ownership changes
   - Handles directories, secrets, and podman storage

### Modified Files

Updated `containerUser` parameter in all affected quadlet configurations:

1. **modules/containers/litellm-quadlet.nix**: container-db → litellm
2. **modules/containers/metabase-quadlet.nix**: container-db → metabase
3. **modules/services/mindsdb.nix**: container-db → mindsdb
4. **modules/containers/nocobase-quadlet.nix**: container-db → nocobase
5. **modules/containers/vanna-quadlet.nix**: container-db → vanna
6. **modules/containers/wallabag-quadlet.nix**: container-db → wallabag
7. **modules/containers/teable-quadlet.nix**: container-db → teable
8. **modules/containers/silly-tavern-quadlet.nix**: container-web → sillytavern
9. **modules/containers/opnsense-exporter-quadlet.nix**: container-monitor → opnsense-exporter
10. **modules/containers/technitium-dns-exporter-quadlet.nix**: container-monitor → technitium-dns-exporter
11. **modules/containers/openspeedtest-quadlet.nix**: container-misc → openspeedtest
12. **modules/containers/paperless-ai-quadlet.nix**: container-misc → paperless-ai

Also updated tmpfilesRules and custom secret handling where applicable.

## Migration Steps

### Phase 1: Preparation (DO THIS FIRST)

1. **Backup Important Data**
   ```bash
   # Backup container data
   sudo tar -czf /tank/Backups/container-migration-$(date +%Y%m%d).tar.gz \
     /var/lib/litellm \
     /var/lib/metabase \
     /var/lib/mindsdb \
     /var/lib/nocobase \
     /var/lib/vanna \
     /var/lib/wallabag \
     /var/lib/teable \
     /var/lib/silly-tavern \
     /var/lib/containers

   # Backup PostgreSQL databases
   sudo systemctl start postgresql-backup.service
   ```

2. **Verify Current State**
   ```bash
   # Check all containers are running
   sudo podman ps -a
   for user in container-db container-web container-monitor container-misc; do
     sudo -u $user podman ps -a
   done

   # Verify services are healthy
   systemctl status litellm metabase mindsdb nocobase vanna wallabag teable \
     silly-tavern opnsense-exporter technitium-dns-exporter speedtest paperless-ai
   ```

3. **Document Current Secrets**
   ```bash
   # List current secrets for reference
   ls -la /run/secrets-container-db/
   ls -la /run/secrets-container-web/
   ls -la /run/secrets-container-monitor/
   ls -la /run/secrets-container-misc/
   ```

### Phase 2: Configuration Switch

4. **Update Configuration Imports**

   Edit `/etc/nixos/hosts/vulcan/default.nix` and replace:

   ```nix
   # OLD - Comment out or remove these lines:
   ../../modules/users/container-users.nix
   ../../modules/users/home-manager/container-db.nix
   ../../modules/users/home-manager/container-web.nix
   ../../modules/users/home-manager/container-monitor.nix
   ../../modules/users/home-manager/container-misc.nix
   ```

   With:

   ```nix
   # NEW - Add these lines:
   ../../modules/users/container-users-dedicated.nix
   ../../modules/users/home-manager/container-users-dedicated.nix
   ```

5. **Build New Configuration (Test First)**
   ```bash
   # Test build without switching
   sudo nixos-rebuild build --flake '.#vulcan'

   # If build succeeds, check what will change
   nix store diff-closures /run/current-system ./result
   ```

### Phase 3: SOPS Secrets Update

6. **Update SOPS Secrets for New Users**

   The following secrets need to be accessible to their new dedicated users. These are currently owned by the shared users and will be automatically re-created by SOPS with the new owners when you rebuild:

   - `litellm-secrets` → will be owned by litellm
   - `metabase-env` → will be owned by metabase
   - `mindsdb/env` → will be owned by mindsdb
   - `nocobase-secrets` → will be owned by nocobase
   - `vanna-env` → will be owned by vanna
   - `wallabag-secrets` → will be owned by wallabag
   - `teable-env` → will be owned by teable
   - (silly-tavern has no secrets)
   - `opnsense-exporter-secrets` → will be owned by opnsense-exporter
   - `technitium-dns-exporter-env` → will be owned by technitium-dns-exporter
   - (openspeedtest has no secrets)
   - (paperless-ai secrets handled by systemd service)

   **Action Required**: None - SOPS will automatically deploy secrets to the new `/run/secrets-<service>/` directories with correct ownership when you run `nixos-rebuild switch`.

### Phase 4: SSL Certificates

7. **Generate New SSL Certificates (If Needed)**

   Check if any services need new SSL certificates:

   ```bash
   # Check existing certificates
   ls -la /var/lib/nginx-certs/
   ```

   The following services have nginx virtual hosts and may need certificates:
   - litellm.vulcan.lan
   - metabase.vulcan.lan
   - mindsdb.vulcan.lan
   - nocobase.vulcan.lan
   - vanna.vulcan.lan
   - wallabag.vulcan.lan
   - teable.vulcan.lan
   - silly-tavern.vulcan.lan (hostname: sillytavern.vulcan.lan)
   - speedtest.vulcan.lan
   - paperless-ai.vulcan.lan

   These certificates are generated automatically by systemd services or can be created manually:

   ```bash
   # Example for any missing certificate:
   sudo /etc/nixos/certs/renew-certificate.sh <hostname>.vulcan.lan \
     -o /var/lib/nginx-certs -d 365 --owner root:nginx
   ```

### Phase 5: Switch to New Configuration

8. **Apply New Configuration**
   ```bash
   # Switch to new configuration
   sudo nixos-rebuild switch --flake '.#vulcan'
   ```

   This will:
   - Create 12 new dedicated users
   - Create new home directories
   - Create new secrets directories
   - Deploy secrets to new locations
   - Stop old services
   - Start new services with new users

9. **Run Migration Script**
   ```bash
   # Migrate data ownership
   sudo /etc/nixos/scripts/migrate-container-users.sh
   ```

   This script will:
   - Stop all affected containers
   - Change ownership of data directories
   - Migrate home directories
   - Copy secrets to new locations
   - Create podman storage directories

### Phase 6: Verification

10. **Verify New Services**
    ```bash
    # Check all services started
    systemctl status litellm metabase mindsdb nocobase vanna wallabag teable \
      silly-tavern opnsense-exporter technitium-dns-exporter speedtest paperless-ai

    # Check containers are running under new users
    sudo -u litellm podman ps
    sudo -u metabase podman ps
    sudo -u mindsdb podman ps
    sudo -u nocobase podman ps
    sudo -u vanna podman ps
    sudo -u wallabag podman ps
    sudo -u teable podman ps
    sudo -u sillytavern podman ps
    sudo -u opnsense-exporter podman ps
    sudo -u technitium-dns-exporter podman ps
    sudo -u openspeedtest podman ps
    sudo -u paperless-ai podman ps

    # Verify web interfaces are accessible
    curl -k https://litellm.vulcan.lan
    curl -k https://metabase.vulcan.lan
    curl -k https://mindsdb.vulcan.lan
    curl -k https://nocobase.vulcan.lan
    curl -k https://vanna.vulcan.lan
    curl -k https://wallabag.vulcan.lan
    curl -k https://teable.vulcan.lan
    curl -k https://sillytavern.vulcan.lan
    curl -k https://speedtest.vulcan.lan
    curl -k https://paperless-ai.vulcan.lan

    # Check Prometheus exporters
    curl http://127.0.0.1:9273/metrics  # opnsense-exporter
    curl http://127.0.0.1:9274/metrics  # technitium-dns-exporter

    # Check logs for errors
    for service in litellm metabase mindsdb nocobase vanna wallabag teable \
      silly-tavern opnsense-exporter technitium-dns-exporter speedtest paperless-ai; do
      echo "=== $service ==="
      sudo journalctl -u $service.service --since "5 minutes ago" | tail -20
    done
    ```

11. **Verify Database Connections**
    ```bash
    # Services using PostgreSQL should connect successfully
    # Check their logs for database connection messages
    sudo journalctl -u litellm.service | grep -i postgres
    sudo journalctl -u metabase.service | grep -i postgres
    sudo journalctl -u mindsdb.service | grep -i postgres
    sudo journalctl -u nocobase.service | grep -i postgres
    sudo journalctl -u wallabag.service | grep -i postgres
    sudo journalctl -u teable.service | grep -i postgres
    ```

### Phase 7: Cleanup (Optional)

12. **Remove Old Shared Users (After Successful Migration)**

    **WAIT AT LEAST 1 WEEK** after migration before removing old users to ensure everything works correctly.

    ```bash
    # Stop any remaining services using old users
    # (Should be none if migration was successful)

    # Remove old user home directories (backup first!)
    sudo tar -czf /tank/Backups/old-container-users-$(date +%Y%m%d).tar.gz \
      /var/lib/containers/container-db \
      /var/lib/containers/container-web \
      /var/lib/containers/container-monitor \
      /var/lib/containers/container-misc

    # Remove old directories
    sudo rm -rf /var/lib/containers/container-db
    sudo rm -rf /var/lib/containers/container-web
    sudo rm -rf /var/lib/containers/container-monitor
    sudo rm -rf /var/lib/containers/container-misc

    # Remove old secrets directories
    sudo rm -rf /run/secrets-container-db
    sudo rm -rf /run/secrets-container-web
    sudo rm -rf /run/secrets-container-monitor
    sudo rm -rf /run/secrets-container-misc

    # Remove old users from NixOS configuration
    # Edit hosts/vulcan/default.nix and completely remove:
    #   ../../modules/users/container-users.nix
    #   ../../modules/users/home-manager/container-db.nix
    #   ../../modules/users/home-manager/container-web.nix
    #   ../../modules/users/home-manager/container-monitor.nix
    #   ../../modules/users/home-manager/container-misc.nix

    # Rebuild to remove old users
    sudo nixos-rebuild switch --flake '.#vulcan'
    ```

## Rollback Procedure

If you encounter issues and need to rollback:

1. **Switch Back to Previous Configuration**
   ```bash
   # List available generations
   sudo nix-env -p /nix/var/nix/profiles/system --list-generations

   # Rollback to previous generation
   sudo nixos-rebuild switch --rollback

   # Or switch to specific generation
   sudo /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration switch
   ```

2. **Restore Data Ownership**
   ```bash
   # Restore from backup if needed
   cd /
   sudo tar -xzf /tank/Backups/container-migration-<date>.tar.gz

   # Or manually fix ownership
   sudo chown -R container-db:container-db /var/lib/litellm
   sudo chown -R container-db:container-db /var/lib/metabase
   # ... etc for all services
   ```

3. **Restart Services**
   ```bash
   systemctl restart litellm metabase mindsdb nocobase vanna wallabag teable \
     silly-tavern opnsense-exporter technitium-dns-exporter speedtest paperless-ai
   ```

## Troubleshooting

### Service Won't Start

```bash
# Check service status and logs
sudo systemctl status <service>.service
sudo journalctl -u <service>.service -n 100

# Common issues:
# 1. Permission denied on data directory
sudo chown -R <new-user>:<new-user> /var/lib/<service>

# 2. Secret file not found
ls -la /run/secrets-<new-user>/
sudo systemctl restart sops-nix.service
sudo nixos-rebuild switch --flake '.#vulcan'

# 3. Container image not found
sudo -u <new-user> podman pull <image-name>
```

### Container Image Missing

```bash
# Each user needs their own copy of the image
# Pull manually if needed
sudo -u <new-user> podman pull <image-url>

# Or restart service to trigger automatic pull
sudo systemctl restart <service>.service
```

### Database Connection Failed

```bash
# Verify PostgreSQL is running
sudo systemctl status postgresql

# Check if user exists and has correct password
sudo -u postgres psql -c "\\du"

# Test connection
sudo -u <new-user> psql -h 127.0.0.1 -U <service> -d <service> -c "SELECT 1"
```

## Security Considerations

### Process Isolation
Each service now runs under its own UID, providing kernel-level process isolation.

### Filesystem Isolation
Each service has its own home directory with restrictive permissions (0700).

### Secret Isolation
Secrets are deployed to per-user directories (`/run/secrets-<user>/`) with 0750 permissions.

### Network Isolation
All services use slirp4netns for networking, preventing direct container-to-container communication.

### Audit Trail
Each user has separate systemd journal entries, making security auditing easier.

## Maintenance

### Adding New Container Services

When adding new services, always create a dedicated user:

```nix
# In container-users-dedicated.nix
myservice = {
  isSystemUser = true;
  group = "myservice";
  home = "/var/lib/containers/myservice";
  createHome = true;
  shell = pkgs.bash;
  autoSubUidGidRange = true;
  linger = true;
  extraGroups = [ "podman" ];
  description = "Container user for MyService";
};

# In home-manager/container-users-dedicated.nix
# Add "myservice" to containerUsers list

# In service quadlet configuration
containerUser = "myservice";
```

### Monitoring

Monitor user resource usage:

```bash
# Check disk usage per user
for user in litellm metabase mindsdb nocobase vanna wallabag teable sillytavern \
  opnsense-exporter technitium-dns-exporter openspeedtest paperless-ai; do
  echo "=== $user ==="
  sudo du -sh /var/lib/containers/$user
  sudo du -sh /var/lib/$user 2>/dev/null || echo "No data directory"
done

# Check memory usage
ps aux | grep -E 'litellm|metabase|mindsdb|nocobase|vanna|wallabag|teable|sillytavern|opnsense|technitium|openspeedtest|paperless-ai'
```

## Questions & Answers

**Q: Why not use Docker/Podman native user namespacing?**
A: We do use user namespacing (autoSubUidGidRange = true), but we add an additional layer by running each container under a different system user for defense in depth.

**Q: Will this use more disk space?**
A: Yes, slightly. Each user will have their own podman storage, but container images are deduplicated via content-addressable storage.

**Q: Can services still communicate with each other?**
A: Yes, through the network stack (podman bridge, localhost, host services). Filesystem isolation doesn't affect network communication.

**Q: What about pod-based services?**
A: Pods (monica, budget-board) remain as root containers. Converting them requires different approach due to pod architecture.

**Q: Do I need to update secrets.yaml?**
A: No. The secret values don't change, only the deployment paths and ownership change automatically.

## References

- NixOS Manual: https://nixos.org/manual/nixos/stable/
- Podman Rootless: https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- Security Best Practices: https://www.cisecurity.org/benchmark/docker
- CLAUDE.md: Critical safety rules and system overview

---

**Migration prepared by**: Claude Code
**Date**: 2025-11-09
**Status**: Ready for user activation
