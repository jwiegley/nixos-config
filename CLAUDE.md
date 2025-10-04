# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a NixOS configuration for the host "vulcan" - an x86_64 Linux system running on Apple T2 hardware. This configuration uses Nix flakes with nixos-hardware and nixos-logwatch modules.

## Commands

### System Management
```bash
# Build and switch to new configuration
sudo nixos-rebuild switch --flake .#vulcan

# Just build without switching
sudo nixos-rebuild build --flake .#vulcan

# Test configuration in a VM
sudo nixos-rebuild build-vm --flake .#vulcan

# Update flake inputs
nix flake update

# Format Nix files (using nixfmt-rfc-style)
nix fmt
```

### Maintenance Commands
```bash
# Check Nix store integrity
nix-store --verify --check-contents

# Garbage collect old generations
sudo nix-collect-garbage -d

# Delete generations older than 30 days
sudo nix-collect-garbage --delete-older-than 30d

# Optimize Nix store
nix-store --optimise
```

### Certificate Authority Management
```bash
# Check step-ca service status
sudo systemctl status step-ca
sudo journalctl -u step-ca -f  # Follow logs

# Generate a new certificate
step ca certificate "service.vulcan.local" service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca/certs/root_ca.crt

# Renew a certificate
step ca renew service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca/certs/root_ca.crt

# List issued certificates
step ca certificate list \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca/certs/root_ca.crt

# Export root CA certificate for client installation
sudo cp /var/lib/step-ca/certs/root_ca.crt ~/vulcan-ca.crt
```

### Dovecot Full-Text Search (FTS) Management
```bash
# Index all mailboxes for a user (initial setup)
doveadm index -u johnw '*'
doveadm index -u assembly '*'

# Index a specific mailbox
doveadm index -u johnw INBOX

# Optimize FTS indexes (reduce index size, improve performance)
doveadm fts optimize -u johnw
doveadm fts optimize -u assembly

# Rescan mailbox and rebuild FTS index (if index is corrupted)
doveadm fts rescan -u johnw
doveadm index -u johnw '*'

# Check Dovecot FTS configuration
doveconf plugin | grep fts

# Monitor FTS indexing activity in logs
sudo journalctl -u dovecot2 -f | grep -i fts

# Search from command line (test FTS functionality)
doveadm search -u johnw body "search term"

# Get mailbox statistics including FTS index size
doveadm mailbox status -u johnw all '*'
```

### Samba File Sharing Management
```bash
# Check Samba service status
sudo systemctl status smbd nmbd samba-wsdd
sudo journalctl -u smbd -f  # Follow Samba logs

# Manage Samba users
sudo smbpasswd -a johnw     # Add user to Samba
sudo smbpasswd -e johnw     # Enable Samba user
sudo smbpasswd -d johnw     # Disable Samba user
sudo pdbedit -L             # List all Samba users
sudo pdbedit -Lv johnw      # Detailed info for user

# Test Samba configuration
sudo testparm               # Validate smb.conf
sudo testparm -s            # Show full configuration

# List shares and test connections
smbclient -L //vulcan.lan -U johnw               # List all shares
smbclient //vulcan.lan/johnw-documents -U johnw  # Connect to share
smbclient -N -L //vulcan.lan                     # Anonymous list (should fail)

# Check active Samba connections
sudo smbstatus              # Show all connections
sudo smbstatus -b           # Brief output
sudo smbstatus -S           # Show shares only
sudo smbstatus -p           # Show processes only

# Monitor Samba activity
sudo journalctl -u smbd -u nmbd -f
sudo tail -f /var/log/samba/log.*

# Set proper ZFS permissions for shares
sudo chown -R johnw:johnw /tank/Documents /tank/Downloads /tank/Home
sudo chown -R :users /tank/Media /tank/Music /tank/Photos /tank/Pictures /tank/Video
sudo chmod -R 0775 /tank/Media /tank/Music /tank/Photos /tank/Pictures /tank/Video
```

### Connecting to Samba Shares

**From Windows:**
```cmd
# Map network drive
net use Z: \\vulcan.lan\johnw-documents /user:johnw

# Or use File Explorer: \\vulcan.lan\share-name
```

**From macOS:**
```bash
# Finder: Cmd+K, then enter: smb://vulcan.lan/johnw-documents

# Command line mount
mkdir -p ~/mnt/documents
mount_smbfs //johnw@vulcan.lan/johnw-documents ~/mnt/documents
```

**From Linux:**
```bash
# Install cifs-utils first
sudo apt install cifs-utils  # Debian/Ubuntu
sudo dnf install cifs-utils  # Fedora

# Mount share
sudo mkdir -p /mnt/samba/documents
sudo mount -t cifs //vulcan.lan/johnw-documents /mnt/samba/documents -o username=johnw

# Add to /etc/fstab for persistent mount
//vulcan.lan/johnw-documents /mnt/samba/documents cifs credentials=/home/user/.smbcredentials,uid=1000,gid=1000 0 0
```

## Architecture

### Core Structure
- **flake.nix**: Main flake defining the NixOS configuration for vulcan host
- **configuration.nix**: Primary system configuration including:
  - Boot configuration (systemd-boot, LUKS encryption)
  - Network setup (NetworkManager, Tailscale, Nebula)
  - Service configurations (PostgreSQL, Restic backups, Docker)
  - User and package management
- **hardware-configuration.nix**: Hardware-specific configuration (generated by nixos-generate-config)

### Key Services Configured
1. **Restic Backups**: Automated backup system with multiple filesets to rsync.net
2. **PostgreSQL**: Database server with custom configuration
3. **Docker**: Container runtime with rootless support
4. **Tailscale & Nebula**: VPN networking
5. **Logwatch**: System log monitoring and reporting
6. **Step-CA**: Private certificate authority for TLS and SSH certificates
7. **Dovecot**: IMAP mail server with full-text search (FTS) via Xapian backend
8. **Samba**: SMB/CIFS file sharing for ZFS tank datasets with SMB3.1.1 encryption

### Important Configuration Details
- **State Version**: 25.05 (DO NOT change unless migrating)
- **Boot**: Uses systemd-boot with LUKS encryption on root partition
- **Networking**: Static hostname "vulcan", uses NetworkManager
- **Time Zone**: America/Los_Angeles
- **Users**: Primary user "johnw" with sudo access via wheel group

### Custom Functions
- **restic-operations**: Shell script for managing Restic backup operations (check, prune, repair, snapshots)
- Supports operations on multiple backup filesets defined in services.restic.backups

## Development Notes

- System runs on Apple T2 hardware (uses nixos-hardware.nixosModules.apple-t2)
- PostgreSQL configured with custom settings for production use
- Restic backups configured with multiple filesets backing up to rsync.net
- Extensive package list including development tools, system utilities, and user applications
- Uses unstable nixpkgs channel for latest packages