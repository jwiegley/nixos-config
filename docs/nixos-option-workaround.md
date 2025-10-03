# nixos-option systemd.services Issue and Workaround

## Problem

Running `nixos-option systemd.services` fails with errors like:
```
error: The option `systemd.services.SERVICE.startLimitBurst' was accessed but has no value defined.
```

**Important:** This is purely an evaluation tool issue. Your NixOS system builds and runs correctly - only the `nixos-option` command is affected.

## Root Cause

The NixOS systemd module defines `startLimitBurst` and `startLimitIntervalSec` options without default values in `nixos/lib/systemd-unit-options.nix`. When `nixos-option` tries to evaluate all services at once, it fails on services (especially dynamically-generated ones like ACME) that don't explicitly set these values.

## Why Can't This Be Fixed Locally?

Several approaches were attempted:

1. **Global default injection**: Causes infinite recursion because reading `config.systemd.services` to apply defaults requires evaluating `config.systemd.services`
2. **Per-service fixes**: Causes conflicts when modules (like ACME) already manage these values differently
3. **Option type override**: Would require overriding the entire NixOS systemd module system

The only proper fix is upstream in nixpkgs.

## Workarounds

### 1. Query Specific Services

Instead of querying all services, query specific ones:
```bash
nixos-option systemd.services.nginx
nixos-option systemd.services.sshd
```

### 2. Use the Wrapper Script

A wrapper script is available that provides better error handling:
```bash
/etc/nixos/scripts/nixos-option-wrapper.sh systemd.services
```

### 3. List Services Using Nix

Get a list of services directly from the configuration:
```bash
nix-instantiate --eval -E '
  let
    cfg = (import <nixpkgs/nixos> {
      configuration = /etc/nixos/hosts/vulcan;
    }).config;
  in builtins.attrNames (cfg.systemd.services or {})
' 2>/dev/null | tr ' ' '\n' | sed 's/["\[\]]//g' | sort
```

### 4. Use systemctl for Runtime Information

For runtime service information, use systemctl:
```bash
# List all services
systemctl list-units --type=service

# Get service status
systemctl status SERVICE_NAME

# Get service configuration
systemctl show SERVICE_NAME
```

## Permanent Fix

The proper fix requires patching nixpkgs to add default values:

```nix
# In nixos/lib/systemd-unit-options.nix
startLimitBurst = mkOption {
  type = types.int;
  default = 5;  # Add this line
  description = "...";
};

startLimitIntervalSec = mkOption {
  type = types.int;
  default = 10;  # Add this line
  description = "...";
};
```

## Upstream Issue

This should be reported to nixpkgs as a bug. The systemd defaults are:
- DefaultStartLimitBurst=5
- DefaultStartLimitIntervalSec=10s

These should be reflected in the NixOS option definitions.