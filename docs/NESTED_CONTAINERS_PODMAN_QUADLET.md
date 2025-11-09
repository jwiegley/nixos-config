# Comprehensive Answer: Rootless Podman Quadlets in NixOS Containers

**YES**, you can run rootless Podman quadlet containers within secure NixOS containers (systemd-nspawn). This is a supported configuration with proper setup, following community best practices.

## Architecture Overview

```
┌─────────────────────────────────────────┐
│ Host NixOS System                       │
│  ├─ User namespaces enabled             │
│  ├─ FUSE kernel module loaded           │
│  └─ Security controls                   │
│                                         │
│  ┌───────────────────────────────────┐ │
│  │ NixOS Container (systemd-nspawn)  │ │
│  │  ├─ User namespace isolation      │ │
│  │  ├─ Podman + quadlet enabled      │ │
│  │  ├─ systemd as PID 1              │ │
│  │  └─ /dev/fuse access (optional*)  │ │
│  │                                   │ │
│  │  ┌─────────────────────────────┐ │ │
│  │  │ Rootless Podman Quadlets    │ │ │
│  │  │  ├─ User-owned containers   │ │ │
│  │  │  ├─ Managed by systemd      │ │ │
│  │  │  └─ OCI containers/pods      │ │ │
│  │  └─────────────────────────────┘ │ │
│  └───────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## NixOS Configuration Requirements

### 1. Host System Configuration

```nix
# /etc/nixos/configuration.nix or module
{
  # User namespaces (enabled by default, but explicitly shown)
  security.allowUserNamespaces = true;

  # FUSE support for legacy/older kernels
  programs.fuse.enable = true;
  programs.fuse.userAllowOther = true;
}
```

### 2. Container Configuration

```nix
# Define a secure container with Podman support
containers.mycontainer = {
  autoStart = true;

  # CRITICAL: Enable user namespace isolation (recommended for security)
  privateUsers = "pick";  # Auto-assigns non-overlapping UID/GID ranges

  # Enable private networking
  privateNetwork = true;
  hostBridge = "br0";

  # Allow access to /dev/fuse for fuse-overlayfs (if kernel < 5.13)
  # Note: Modern kernels (≥5.13) support native rootless overlayfs
  allowedDevices = [
    {
      node = "/dev/fuse";
      modifier = "rwm";
    }
  ];

  # Additional capabilities may be needed for older setups
  # CAP_SYS_ADMIN only if using fuse-overlayfs (not needed for native overlay)
  additionalCapabilities = [
    # "CAP_SYS_ADMIN"  # Only if using fuse-overlayfs
  ];

  # Container configuration
  config = { config, pkgs, ... }: {
    # Enable Podman system-wide
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;  # Optional: docker alias
      defaultNetwork.settings.dns_enabled = true;
    };

    # Enable Home Manager for rootless container management
    home-manager.users.containeruser = { config, ... }: {
      # Rootless Podman containers via Home Manager
      services.podman = {
        enable = true;

        # Define containers as quadlets
        containers = {
          myapp = {
            image = "docker.io/nginx:latest";
            autoStart = true;
            ports = [ "8080:80" ];
          };
        };

        # Define networks
        networks = {
          mynetwork = {
            driver = "bridge";
          };
        };
      };

      # Systemd services for quadlets (for pods)
      systemd.user.services = {
        # Example pod definition (Home Manager lacks native pod support)
        # Use quadlet .pod files in ~/.config/containers/systemd/
      };
    };

    # Create user with proper subuid/subgid mappings
    users.users.containeruser = {
      isNormalUser = true;
      linger = true;  # Enable user services without login
      group = "podman";
      subUidRanges = [
        { startUid = 100000; count = 65536; }
      ];
      subGidRanges = [
        { startGid = 100000; count = 65536; }
      ];
    };

    users.groups.podman = {};

    # Add user to allowed Nix users (not trusted-users!)
    nix.settings.allowed-users = [ "containeruser" ];

    # Storage driver configuration (if not using btrfs)
    environment.etc."containers/storage.conf".text = ''
      [storage]
      driver = "overlay"
      # mount_program is NOT set for native overlayfs (kernel ≥5.13)
      # For older kernels, use: mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
    '';

    # Ensure systemd PATH includes necessary tools
    systemd.services."user@".environment = {
      PATH = lib.mkForce "/run/wrappers/bin:/run/current-system/sw/bin";
    };
  };
};
```

## Security Best Practices

### ✅ Recommended Security Configuration

1. **User Namespace Isolation**: Always use `privateUsers = "pick"`
   - Provides UID/GID isolation between container and host
   - Container root = unprivileged user on host
   - Automatic non-overlapping range assignment

2. **Native Rootless Overlayfs** (Kernel ≥5.13)
   - No `/dev/fuse` device access needed
   - No `CAP_SYS_ADMIN` capability required
   - Better performance and security
   - Verify with: `podman info | grep -A2 graphDriverName`

3. **Minimal Capabilities**
   - Avoid granting `CAP_SYS_ADMIN` if possible
   - Only grant if using fuse-overlayfs on older kernels

4. **Network Isolation**
   - Use `privateNetwork = true`
   - Define explicit port forwarding
   - Restrict outbound access as needed

5. **Home Manager for Rootless**
   - **Critical**: Use Home Manager for user-level containers
   - Direct `systemd.user.services` won't work properly
   - Provides proper lifecycle management

### ⚠️ Security Considerations

**Device Access**:
- `/dev/fuse` access increases attack surface
- Only needed for fuse-overlayfs (kernel < 5.13)
- Modern setups should use native overlayfs

**CAP_SYS_ADMIN**:
- Powerful capability that should be avoided
- Grants significant privileges within the namespace
- Not needed for native rootless overlayfs

**User Linger**:
- Enables services to run without active login
- Required for rootless containers to persist
- Relatively low security risk

## Storage Driver Selection

### Modern Setup (Kernel ≥5.13) - **RECOMMENDED**

```nix
environment.etc."containers/storage.conf".text = ''
  [storage]
  driver = "overlay"
  # mount_program NOT set - uses native overlayfs
'';
```

**Benefits**:
- No FUSE dependency
- No special capabilities needed
- Better performance
- Lower attack surface

### Legacy Setup (Kernel < 5.13)

```nix
# Add to container config
allowedDevices = [
  { node = "/dev/fuse"; modifier = "rwm"; }
];

additionalCapabilities = [ "CAP_SYS_ADMIN" ];

environment.etc."containers/storage.conf".text = ''
  [storage]
  driver = "overlay"
  mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
'';
```

## Quadlet Integration

Podman Quadlet works seamlessly in this setup because:

1. **systemd runs as PID 1** in NixOS containers
2. **User systemd instances** are supported with linger
3. **Quadlet generator** creates systemd units automatically
4. **Home Manager** provides declarative quadlet management

### Manual Quadlet Files (Alternative to Home Manager)

Place in `~/.config/containers/systemd/`:

```ini
# myapp.container
[Container]
Image=docker.io/nginx:latest
PublishPort=8080:80
Network=mynetwork.network

[Service]
Restart=always

[Install]
WantedBy=default.target
```

## Verification Commands

```bash
# Inside the container
podman info | grep -E 'graphDriverName|Native Overlay'
# Should show: graphDriverName: overlay
# Should show: Native Overlay Diff: "true" (if kernel ≥5.13)

# Check user namespaces
cat /proc/self/uid_map
cat /proc/self/gid_map

# Verify quadlet generation
systemctl --user list-units --type=service | grep podman

# Test container creation
podman run --rm hello-world
```

## Community Best Practices Summary

Based on NixOS Discourse discussions and recent developments:

1. **Use Home Manager** for rootless Podman (not direct systemd.user.services)
2. **Enable user namespaces** with `privateUsers = "pick"`
3. **Prefer native overlayfs** over fuse-overlayfs when possible
4. **Minimize capabilities** - avoid CAP_SYS_ADMIN on modern kernels
5. **Use quadlet-nix** project for advanced use cases
6. **Test storage driver** after initial setup
7. **Enable linger** for the container user
8. **Use declarative configuration** rather than imperative setup

## Known Limitations

1. **Historical Issues** (2022): Older discussions show runc failures in unprivileged containers - these have been resolved in modern NixOS
2. **Pod Support**: Home Manager lacks native pod declarations - requires manual systemd service definitions
3. **Storage Migration**: Changing storage drivers requires removing `~/.local/share/containers/storage`
4. **Kernel Requirements**: Native overlayfs requires kernel ≥5.13 (your kernel 6.16.8 supports this)

## Recommended Configuration for Your System

Given your setup (Kernel 6.16.8-asahi on aarch64):

```nix
containers.podman-host = {
  privateUsers = "pick";          # Security: user namespace isolation
  privateNetwork = true;          # Network isolation
  # NO allowedDevices needed      # Kernel 6.16.8 supports native overlayfs
  # NO additionalCapabilities     # Not needed with native overlayfs

  config = { config, pkgs, ... }: {
    virtualisation.podman.enable = true;

    home-manager.users.podmanuser = {
      services.podman = {
        enable = true;
        containers = { /* your quadlets */ };
      };
    };

    users.users.podmanuser = {
      isNormalUser = true;
      linger = true;
      subUidRanges = [{ startUid = 100000; count = 65536; }];
      subGidRanges = [{ startGid = 100000; count = 65536; }];
    };
  };
};
```

This configuration maximizes **security** (user namespaces, no privileged capabilities) and **utility** (native performance, full quadlet support) according to current community best practices.

## Research Sources

This document was compiled from:
- NixOS options documentation (nixpkgs manual)
- Arch Linux Wiki on systemd-nspawn
- NixOS Discourse community discussions
- Perplexity AI search synthesis
- Recent developments in Podman rootless support
- Linux kernel overlayfs improvements (5.13+)

**Last Updated**: 2025-11-09
**System**: NixOS 25.05 on Kernel 6.16.8-asahi (aarch64)
