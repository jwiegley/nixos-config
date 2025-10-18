# Container DNS Resolution - Recurring Issue Documentation

## ⚠️ Critical Issue: Container DNS Misconfiguration

This document explains a recurring bug that has occurred **5+ times** in this NixOS configuration.

## The Problem

Containers created with `mkQuadletService` cannot resolve `.lan` domain names (like `hera.lan`, `athena.lan`, etc.) when DNS is misconfigured.

## Symptoms

When this bug occurs, you'll see errors like:

```
socket.gaierror: [Errno -3] Temporary failure in name resolution
aiohttp.client_exceptions.ClientConnectorDNSError: Cannot connect to host hera.lan:8080 ssl:default [Temporary failure in name resolution]
httpx.ConnectError: Cannot connect to host athena.lan:8080 ssl:default [Temporary failure in name resolution]
```

Specifically affects:
- **litellm**: Cannot load models from hera.lan or athena.lan
- **Other quadlet services**: Cannot communicate with .lan hosts
- **Network requests**: Fail with "Temporary failure in name resolution"

## Root Cause

The bug occurs when DNS is explicitly configured in container settings:

### ❌ Wrong Configuration (Breaks DNS)

```nix
# In mkQuadletService.nix or extraContainerConfig
dns = [ "10.88.0.1" ];
# or
dns = [ common.postgresDefaults.host ];
```

**Why this breaks:**
- `10.88.0.1` is the **Podman bridge gateway** where PostgreSQL listens on port 5432
- It is **NOT a DNS server** - there's no DNS service listening on port 53
- Setting `dns = [...]` **disables Podman's automatic DNS forwarding**
- Containers then can't resolve any `.lan` domains

### ✅ Correct Configuration (Works)

```nix
# In mkQuadletService.nix
containerConfig = {
  # ... other settings ...
  networks = [ "podman" ];
  # NO dns = [...] setting here!
  # Podman automatically forwards to host DNS
};
```

**Why this works:**
- Podman's default behavior copies host DNS servers from `/etc/resolv.conf`
- Host DNS servers (192.168.1.2, 192.168.1.1) can resolve .lan domains
- Automatic forwarding adapts when host DNS changes
- May add 169.254.1.1 (aardvark-dns) for advanced features

## How Podman DNS Works

### Default Behavior (No explicit DNS)
1. Podman reads `/etc/resolv.conf` on the host
2. Copies nameserver entries to container's `/etc/resolv.conf`
3. May add aardvark-dns (169.254.1.1) for inter-container resolution
4. Container can resolve:
   - External domains (via host DNS → ISP DNS)
   - .lan domains (via host DNS → local DNS server)
   - Container names (via aardvark-dns)

### With Explicit DNS Setting
1. Podman **ignores** host's `/etc/resolv.conf`
2. **Only** uses the explicitly configured DNS servers
3. **No automatic forwarding** to host DNS
4. Container can **only** resolve what those DNS servers know

## Why This Keeps Recurring

1. **Misleading variable name**: `common.postgresDefaults.host` sounds like it might be for DNS
2. **Incorrect comment**: Previous comment said "Use host DNS via Podman gateway" which was wrong
3. **Lack of validation**: No build-time check to prevent this misconfiguration
4. **Easy to forget**: When writing new container configs, it's tempting to add DNS settings

## The Fix (Implemented)

### 1. Enhanced Documentation (mkQuadletService.nix:82-119)

Added a prominent warning block with:
- Clear explanation of the correct vs. wrong approach
- Symptoms of the bug
- How Podman DNS works
- When/if to override (spoiler: almost never)

### 2. Build-Time Validation (mkQuadletService.nix:71-103)

Added an assertion that **fails the build** if someone tries to set DNS:

```nix
assertions = [
  {
    assertion = !(extraContainerConfig ? dns);
    message = ''
      ❌ CRITICAL ERROR: DNS configuration detected!
      [detailed error message explaining the issue]
    '';
  }
];
```

This catches the error at `nixos-rebuild build` time instead of at runtime.

### 3. No DNS Configuration in mkQuadletService

The `containerConfig` section has **no `dns` setting**, allowing Podman to use its intelligent defaults.

## Verification

### Check if DNS is Working

```bash
# Check container's DNS configuration
sudo podman exec litellm cat /etc/resolv.conf
# Should show: nameserver 192.168.1.2 and nameserver 192.168.1.1

# Test DNS resolution inside container
sudo podman exec litellm nslookup hera.lan
# Should return: Server: 192.168.1.2, Address: 192.168.1.2#53
#                Name: hera.lan, Address: 192.168.1.X

# Check for DNS errors in service logs
sudo journalctl -u litellm --since "10 minutes ago" | grep -i "dns\|name resolution"
# Should return: 0 errors
```

### Check Quadlet Configuration

```bash
# Check generated quadlet file
sudo cat /etc/containers/systemd/litellm.container | grep -i dns
# Should return: (no output - no DNS= line)
```

## What NOT to Do

### ❌ Don't Add DNS to mkQuadletService

```nix
# DO NOT DO THIS in mkQuadletService.nix:
containerConfig = {
  dns = [ "10.88.0.1" ];  # ← NEVER DO THIS
  dns = [ common.postgresDefaults.host ];  # ← OR THIS
  dns = [ "192.168.1.2" "192.168.1.1" ];  # ← OR EVEN THIS
};
```

### ❌ Don't Add DNS to extraContainerConfig (Usually)

```nix
# DO NOT DO THIS in individual service files:
mkQuadletService {
  name = "myservice";
  # ...
  extraContainerConfig = {
    dns = [ ... ];  # ← This will fail the build (assertion)
  };
}
```

**The assertion will catch this and fail the build with a helpful error message.**

## When You Might Need Custom DNS (Rare Cases)

In 99% of cases, you **don't** need to override DNS. But if you have a special case:

1. **Read all the documentation** in `mkQuadletService.nix` first
2. **Understand the implications** of disabling automatic forwarding
3. **Use extraContainerConfig** in the individual service file, not mkQuadletService
4. **Document WHY** you're overriding the default
5. **Test thoroughly** with `podman exec <container> nslookup hera.lan`
6. **Monitor for DNS errors** after deployment

Example of a legitimate custom DNS (very rare):

```nix
# Only if you have a VERY good reason and documented it thoroughly
mkQuadletService {
  name = "special-service-that-needs-external-dns-only";
  # ...
  extraContainerConfig = {
    # This will fail the assertion - you'd need to modify mkQuadletService
    # to allow bypassing it for specific services with a flag
    dns = [ "8.8.8.8" "1.1.1.1" ];  # External DNS only
  };
}
```

**Note**: The current assertion will prevent this. If you have a legitimate use case, you'll need to:
1. Add a `allowCustomDNS ? false` parameter to mkQuadletService
2. Update the assertion to check for this flag
3. Document the use case extensively

## History of This Bug

This bug has occurred **at least 5 times** in this configuration:

1. **Initial mistake**: Set `dns = [ common.postgresDefaults.host ]` thinking it would help with database connectivity
2. **Regression #1**: Re-added after refactoring, forgot why it was removed
3. **Regression #2**: Copy-pasted from incorrect example
4. **Regression #3**: Thought it would improve DNS performance
5. **Regression #4**: Misunderstood the comment about "host DNS via Podman gateway"
6. **Current fix**: Added validation, enhanced documentation, removed DNS setting

## Prevention Measures

To prevent this from happening again:

### ✅ Build-Time Protection
- Assertion fails build if `dns` is set in `extraContainerConfig`
- Forces developer to read documentation before bypassing

### ✅ Documentation
- Prominent warning in `mkQuadletService.nix`
- This dedicated documentation file
- Clear examples of wrong vs. correct configuration

### ✅ Testing
- Always test `.lan` domain resolution after changes: `podman exec <container> nslookup hera.lan`
- Check service logs for DNS errors: `journalctl -u <service> | grep -i dns`
- Verify quadlet config has no `DNS=` line: `cat /etc/containers/systemd/<service>.container`

### ✅ Code Review
- When reviewing changes to `mkQuadletService.nix`, check for DNS settings
- When adding new quadlet services, verify they use Podman defaults
- Question any DNS-related changes - they're almost never needed

## Summary

**The Golden Rule**: **Never set `dns` in container configuration unless you have an extremely well-documented reason.**

**Current Status**:
- ✅ DNS removed from mkQuadletService
- ✅ Build-time validation added
- ✅ Comprehensive documentation added
- ✅ All quadlet services use Podman DNS defaults
- ✅ `.lan` domain resolution working correctly

**If you see DNS errors again:**
1. Check if someone added `dns = [...]` to mkQuadletService.nix or extraContainerConfig
2. Remove it
3. Read this documentation
4. Update it if needed

This bug **must not** happen a 6th time.
