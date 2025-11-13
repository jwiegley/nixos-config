# Vulcan - Production NixOS Configuration

A production-grade, modular NixOS configuration for self-hosted infrastructure running on Apple hardware using Asahi Linux. This configuration implements a comprehensive stack including web services, mail infrastructure, databases, monitoring, containerized applications, and multi-layer backup strategies.

## 🚀 Key Features

- **🏗️ Modular Architecture**: 70+ well-organized modules across 8 functional categories
- **📊 Full Observability**: Prometheus, Grafana, Alertmanager with custom exporters and alert rules
- **💾 Multi-Layer Backups**: ZFS snapshots + Restic cloud backups to Backblaze B2
- **🔐 Security First**: SOPS-nix secrets management, private CA (step-ca), security hardening
- **📧 Complete Mail Stack**: Postfix, Dovecot with FTS (Xapian), mbsync with Prometheus metrics
- **🐳 Container Orchestration**: Podman/Quadlet-based containers with proper networking
- **🏠 Home-Manager Integration**: Declarative user environment management
- **🍎 Apple Silicon Support**: Hardware-specific optimizations for Apple Silicon compatibility

## 📋 Table of Contents

- [Architecture](#architecture)
- [Infrastructure Components](#infrastructure-components)
- [Hardware & Platform](#hardware--platform)
- [Quick Start](#quick-start)
- [Management Commands](#management-commands)
- [Monitoring & Observability](#monitoring--observability)
- [Module Organization](#module-organization)
- [Secrets Management](#secrets-management)
- [Customization & Extension](#customization--extension)
- [State & Compatibility](#state--compatibility)
- [Contributing](#contributing)

## 🏛️ Architecture

This configuration follows a highly modular architecture, organizing system configuration into discrete, reusable modules by functional domain.

### Module Categories

| Category | Purpose | Key Modules |
|----------|---------|-------------|
| **Core** | System fundamentals | Boot (GRUB/EFI), networking, firewall, Nix config, systemd tuning |
| **Services** | Application services | Web (Nginx), mail, databases, monitoring, DNS |
| **Storage** | Data management | ZFS configuration, snapshots, backups |
| **Containers** | Containerized apps | Podman/Quadlet setup, container services |
| **Security** | Security & secrets | Hardening, SOPS-nix, certificate management |
| **Users** | User management | User configs, home-manager integration |
| **Maintenance** | System maintenance | Timers, logwatch, automation |
| **Packages** | Custom packages | Shell configs, custom tools |

### Design Principles

1. **Separation of Concerns**: Each module has a single, well-defined responsibility
2. **Composability**: Modules can be easily added, removed, or replaced
3. **Reusability**: Common patterns extracted into library functions (e.g., `mkMbsyncModule`)
4. **Declarative**: Everything is version-controlled and reproducible
5. **Production-Ready**: Comprehensive monitoring, alerting, and disaster recovery

## 🏗️ Infrastructure Components

### Web Services

- **Nginx**: Reverse proxy with ACME/Let's Encrypt for internet-facing services
  - Internal services use step-ca certificates
  - HTTP/2, HSTS, security headers
  - Automatic HTTP → HTTPS redirect
- **Glance**: Alternative dashboard with customizable widgets
- **Wallabag**: Read-it-later service (containerized)

### Mail Infrastructure

- **Postfix**: SMTP server with monitoring
- **Dovecot**: IMAP server with full-text search (Xapian backend)
  - FTS indexing for fast email search
  - Multiple virtual users supported
- **mbsync**: Mail synchronization with Prometheus metrics
  - Pull-only sync from Fastmail and Gmail
  - Custom alerts for sync failures
  - Reusable module library (`mkMbsyncModule`)

### Databases & Storage

- **PostgreSQL**: Production database with custom tuning
- **pgAdmin**: Web-based database administration
- **ZFS**: Enterprise-grade filesystem with:
  - Automated snapshots (hourly, daily, monthly)
  - ARC tuning for 64GB RAM system

### Monitoring Stack

- **Prometheus**: Metrics collection and alerting
  - Node exporter (system metrics)
  - PostgreSQL exporter
  - Systemd exporter
  - Postfix exporter
  - ZFS exporter
  - Custom textfile collectors (restic, mbsync)
- **Grafana**: Visualization dashboards
- **Alertmanager**: Alert routing and notifications
- **Blackbox Exporter**: Endpoint monitoring (HTTP, ICMP)

### Security Infrastructure

- **step-ca**: Private certificate authority
  - TLS certificates for internal services
  - SSH certificates
  - Automated certificate renewal
- **SOPS-nix**: Encrypted secrets in git
  - Age/PGP key encryption
  - Secrets available at runtime
- **Security Hardening**: System-level security enhancements

### Containerized Services

All containers use Podman with Quadlet for systemd integration:

- **LiteLLM**: LLM proxy and gateway
- **Wallabag**: Article reading and archiving
- **Silly Tavern**: AI chat interface
- **OPNsense Exporter**: Firewall metrics (with custom API transformer)
- **Secure Nginx**: Isolated nginx container for specific services

### Backup & Disaster Recovery

**ZFS Snapshots (Sanoid)**:
- `active` template: Hourly (24), Daily (7), Monthly (3)
- `archival` template: Hourly (24), Daily (30), Weekly (8), Monthly (12), Yearly (5)
- `production` template: Hourly (24), Daily (14), Weekly (4), Monthly (3)

**Restic Cloud Backups** (to Backblaze B2):
- Multiple backup filesets (home, documents, projects, etc.)
- Daily at 2 AM with persistent timers
- Retention: 7 daily, 5 weekly, 3 yearly
- Monitoring via Prometheus textfile collector
- Helper script: `restic-operations` (check, snapshots, prune, repair)

### Additional Services

- **DNS**: Technitium DNS Server
- **Network Services**: Tailscale, Nebula VPN
- **Media Services**: Configured media management

## 🖥️ Hardware & Platform

### System Specifications

- **Platform**: Apple Hardware (aarch64-linux)
- **RAM**: 64GB (ZFS ARC: 32GB max, 4GB min)
- **Storage**: ZFS on multiple pools
  - `rpool`: System and home directories
  - `tank`: Data storage with replication
- **Network**: NetworkManager with static hostname
- **External Storage**: USB-C device auto-enrollment

### Hardware Configuration

- **Boot**: GRUB with EFI support
  - ZFS ARC tuning for 64GB RAM
- **Post-boot**: PCI rescan for device discovery

## 🚀 Quick Start

### Prerequisites

1. NixOS installed on Apple hardware
2. Age/PGP keys for SOPS secrets decryption
3. Access to Backblaze B2 for backups (optional)

### Initial Setup

```bash
# Clone the repository
git clone <repository-url> /etc/nixos
cd /etc/nixos

# Configure your secrets (copy and edit)
# Set up SOPS keys and decrypt secrets
# See "Secrets Management" section below

# Update flake inputs
nix flake update

# Build and switch to new configuration
sudo nixos-rebuild switch --flake .#vulcan
```

### Testing Changes

```bash
# Build without switching (test for errors)
sudo nixos-rebuild build --flake .#vulcan

# Test in a VM (requires virtualization support)
sudo nixos-rebuild build-vm --flake .#vulcan
```

## 🛠️ Management Commands

### System Management

```bash
# Build and activate new configuration
sudo nixos-rebuild switch --flake .#vulcan

# Just build without switching
sudo nixos-rebuild build --flake .#vulcan

# Test configuration in a VM
sudo nixos-rebuild build-vm --flake .#vulcan

# Update flake inputs
nix flake update

# Format Nix files (nixfmt-rfc-style)
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

# Optimize Nix store (deduplicate)
nix-store --optimise
```

### Certificate Authority (step-ca)

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

# Export root CA for client installation
sudo cp /var/lib/step-ca/certs/root_ca.crt ~/vulcan-ca.crt
```

### Dovecot Full-Text Search (FTS)

```bash
# Index all mailboxes for a user (initial setup)
doveadm index -u johnw '*'
doveadm index -u assembly '*'

# Index a specific mailbox
doveadm index -u johnw INBOX

# Optimize FTS indexes (reduce size, improve performance)
doveadm fts optimize -u johnw
doveadm fts optimize -u assembly

# Rescan and rebuild FTS index (if corrupted)
doveadm fts rescan -u johnw
doveadm index -u johnw '*'

# Test FTS search functionality
doveadm search -u johnw body "search term"

# Check mailbox statistics including FTS index size
doveadm mailbox status -u johnw all '*'
```

### Backup Operations

```bash
# Check all backup filesets
restic-operations check

# View recent snapshots
restic-operations snapshots
# Or use the dedicated command:
restic-snapshots

# Manual backup operations (per fileset)
restic-home check
restic-documents snapshots
restic-projects prune
```

### Container Management

```bash
# Interactive container management
lazydocker  # TUI for Docker/Podman
podman-tui  # Alternative Podman TUI

# List running containers
podman ps

# View container logs
journalctl -u quadlet-<service-name> -f

# Restart a container service
sudo systemctl restart quadlet-<service-name>
```

### ZFS Management

```bash
# Check pool status
zpool status

# List ZFS filesystems and snapshots
zfs list -t all

# View recent snapshots per filesystem
logwatch-zfs-snapshot
```

## 📊 Monitoring & Observability

### Prometheus Exporters

| Exporter | Port | Metrics |
|----------|------|---------|
| Node | 9100 | CPU, memory, disk, network, systemd |
| PostgreSQL | 9187 | Database stats, connections, queries |
| Systemd | 9558 | Service status, failures, restarts |
| Postfix | 9154 | Mail queue, delivery stats |
| ZFS | 9134 | Pool health, dataset usage, I/O |
| Restic | Textfile | Backup status, snapshot counts |
| mbsync | Textfile | Sync status, message counts |

### Alert Rules

Located in `modules/monitoring/alerts/`:

- **system.yaml**: CPU, memory, disk alerts
- **systemd.yaml**: Service failures, restarts
- **database.yaml**: PostgreSQL connection and performance
- **storage.yaml**: ZFS pool health, disk space
- **certificates.yaml**: Certificate expiration warnings
- **network.yaml**: Network connectivity and performance

### Grafana Dashboards

Access Grafana for visualization:
- URL: `https://grafana.vulcan.lan`
- Pre-configured dashboards for all exporters
- Custom dashboards for service-specific metrics

### Logwatch Reports

Daily email reports include:

- Failed systemctl services
- SSH authentication attempts
- Sudo usage
- Kernel messages
- Audit logs
- ZFS pool status
- Restic backup snapshots
- ZFS snapshots overview
- Certificate validation report

## 📁 Module Organization

### Directory Structure

```
/etc/nixos/
├── flake.nix                      # Flake definition and inputs
├── hosts/
│   └── vulcan/
│       ├── default.nix            # Main host configuration
│       └── hardware-configuration.nix
├── modules/
│   ├── core/                      # System fundamentals
│   │   ├── boot.nix
│   │   ├── networking.nix
│   │   ├── firewall.nix
│   │   ├── nix.nix
│   │   ├── system.nix
│   │   ├── programs.nix
│   │   └── systemd-rate-limit-fix.nix
│   ├── services/                  # Service configurations
│   │   ├── web.nix
│   │   ├── dovecot.nix
│   │   ├── postfix.nix
│   │   ├── mbsync.nix
│   │   ├── databases.nix
│   │   ├── certificates.nix
│   │   ├── monitoring.nix
│   │   ├── prometheus-monitoring.nix
│   │   ├── grafana.nix
│   │   └── ...
│   ├── storage/                   # Storage and backups
│   │   ├── zfs.nix
│   │   ├── backups.nix
│   │   └── backup-monitoring.nix
│   ├── containers/                # Container services
│   │   ├── quadlet.nix
│   │   ├── litellm-quadlet.nix
│   │   ├── wallabag-quadlet.nix
│   │   └── ...
│   ├── security/                  # Security configurations
│   │   └── hardening.nix
│   ├── users/                     # User management
│   │   ├── default.nix
│   │   ├── johnw.nix
│   │   ├── assembly.nix
│   │   └── home-manager/
│   ├── maintenance/               # Maintenance tasks
│   │   └── timers.nix
│   ├── packages/                  # Package configurations
│   │   ├── custom.nix
│   │   └── zsh.nix
│   ├── lib/                       # Reusable functions
│   │   └── mkMbsyncModule.nix
│   ├── monitoring/                # Monitoring configs
│   │   └── alerts/                # Prometheus alert rules
│   └── options/                   # Custom options
├── certs/                         # Certificate scripts
├── scripts/                       # Helper scripts
└── secrets.yaml                   # SOPS encrypted secrets
```

### Adding New Modules

1. Create module file in appropriate category directory
2. Import in `hosts/vulcan/default.nix`
3. Follow existing patterns for consistency
4. Test with `nixos-rebuild build`

Example module structure:

```nix
{ config, lib, pkgs, ... }:

{
  # Service configuration
  services.myservice = {
    enable = true;
    # ... configuration options
  };

  # Networking/firewall if needed
  networking.firewall.allowedTCPPorts = [ 1234 ];

  # Systemd services if needed
  systemd.services.myservice-helper = {
    # ... service definition
  };

  # Packages
  environment.systemPackages = with pkgs; [
    # ... packages
  ];
}
```

## 🔐 Secrets Management

This configuration uses **SOPS-nix** for managing secrets securely in git.

### How It Works

1. Secrets are encrypted with Age/PGP keys
2. Encrypted `secrets.yaml` is committed to git
3. At activation, secrets are decrypted and placed in `/run/secrets/`
4. Services reference secrets via SOPS paths

### Secret Configuration

**Never decrypt or expose secrets in plain text!**

Secrets are referenced in modules like this:

```nix
services.step-ca = {
  intermediatePasswordFile = config.sops.secrets."step-ca-password".path;
};

services.restic.backups.home = {
  passwordFile = "/run/secrets/restic-password";
  environmentFile = "/run/secrets/aws-keys";
};
```

### Adding New Secrets

1. Edit `secrets.yaml` with `sops secrets.yaml`
2. Add secret reference in module:
   ```nix
   sops.secrets."my-new-secret" = {
     owner = "service-user";
     group = "service-group";
     mode = "0400";
   };
   ```
3. Reference in service: `config.sops.secrets."my-new-secret".path`

### Required Secrets

The following secrets are used (see `secrets.yaml` for complete list):

- `step-ca-password`: CA intermediate key password
- `restic-password`: Restic backup encryption password
- `aws-keys`: Backblaze B2 credentials
- `johnw-fastmail-password`: Mail account password
- `carmichael-imap-gmail-com`: Gmail app password
- Database passwords
- API keys and tokens

## 🎨 Customization & Extension

### Reusable Patterns

#### mkMbsyncModule Library

Create reusable mbsync configurations:

```nix
let
  mkMbsyncLib = import ../lib/mkMbsyncModule.nix { inherit config lib pkgs; };
  inherit (mkMbsyncLib) mkMbsyncService;
in
{
  imports = [
    (mkMbsyncService {
      name = "myaccount";
      user = "myuser";
      group = "mygroup";
      secretName = "my-imap-password";
      remoteConfig = ''
        Host imap.example.com
        User myuser@example.com
        PassCmd "cat /run/secrets/my-imap-password"
        # ... more config
      '';
      channels = ''
        # ... channel config
      '';
      timerInterval = "15min";
    })
  ];
}
```

#### Custom Service Patterns

Many services follow similar patterns:

1. **Service configuration**: Main service setup
2. **Secrets integration**: SOPS secret references
3. **Monitoring**: Prometheus exporter
4. **Alerts**: Alert rules in `modules/monitoring/alerts/`
5. **Backup**: Include in Restic backups if needed

### Flake Inputs & Overlays

Current flake inputs:

- `nixpkgs`: nixos-unstable channel
- `nixos-apple-silicon`: Apple hardware support
- `home-manager`: User environment management
- `sops-nix`: Secrets management
- `nixos-logwatch`: Log monitoring
- `quadlet-nix`: Podman container integration
- `claude-code-nix`: Claude Code overlay

Add new inputs in `flake.nix`:

```nix
inputs = {
  my-input.url = "github:user/repo";
};

outputs = { nixpkgs, my-input, ... }: {
  nixosConfigurations.vulcan = nixpkgs.lib.nixosSystem {
    modules = [
      my-input.nixosModules.default
      # ...
    ];
  };
};
```

## 📌 State & Compatibility

### NixOS State Version

```nix
system.stateVersion = "25.05";
```

**⚠️ Important**: This value determines compatibility for stateful data. Do not change unless migrating the system. See [NixOS Manual](https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion) for details.

### Channel & Version

- **NixOS Version**: 25.05
- **nixpkgs Channel**: `nixos-unstable`
- **System Architecture**: x86_64-linux

### Flake Lock

The `flake.lock` file pins all input versions for reproducibility. Update with:

```bash
# Update all inputs
nix flake update

# Update specific input
nix flake lock --update-input nixpkgs
```

## 🤝 Contributing

### Code Style

- **Formatting**: Use `nix fmt` (nixfmt-rfc-style)
- **Indentation**: 2 spaces
- **Line Length**: Keep reasonable (80-100 chars when possible)
- **Comments**: Document complex logic and design decisions

### Module Guidelines

1. **Single Responsibility**: Each module should have one clear purpose
2. **Minimal Dependencies**: Avoid unnecessary inter-module dependencies
3. **Reusability**: Extract common patterns to `lib/`
4. **Documentation**: Add comments for non-obvious configurations
5. **Testing**: Test changes with `nixos-rebuild build` before committing

### Commit Messages

Follow conventional commits:

- `feat: Add new service module`
- `fix: Correct Dovecot FTS configuration`
- `refactor: Extract mbsync to library function`
- `docs: Update README with backup procedures`
- `chore: Update flake inputs`

### Development Workflow

1. Create a feature branch
2. Make changes in appropriate module
3. Test with `sudo nixos-rebuild build --flake .#vulcan`
4. Test in VM if possible: `sudo nixos-rebuild build-vm --flake .#vulcan`
5. Format code: `nix fmt`
6. Commit with clear message
7. Submit pull request (if applicable)

### Debugging

```bash
# Check Nix evaluation without building
nix eval .#nixosConfigurations.vulcan.config.system.build.toplevel

# Show full build log
sudo nixos-rebuild switch --flake .#vulcan --show-trace

# Verify module imports
nix eval .#nixosConfigurations.vulcan.config.imports --json | jq
```

## 📚 Additional Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Nix Flakes Guide](https://nixos.wiki/wiki/Flakes)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [SOPS-nix Documentation](https://github.com/Mic92/sops-nix)
- [nixos-hardware](https://github.com/NixOS/nixos-hardware)

## 📄 License

This configuration is for personal use. Adapt and modify as needed for your own infrastructure.

---

**System**: Vulcan • **Platform**: Apple M1 (aarch64-linux) • **NixOS**: 25.05 (unstable)
