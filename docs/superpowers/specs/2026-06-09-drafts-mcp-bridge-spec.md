# Drafts MCP Bridge (hera) → OpenClaw / Hermes / Host Claude Code — Implementation Spec

> **Archival — 2026-06-09.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/services/drafts-mcp.nix`).

**Date:** 2026-06-09
**Status:** Spec — ready to implement
**Author:** Claude (Opus 4.8) with John Wiegley
**Topic slug:** `drafts-mcp-bridge`
**Repos touched:**
- `/Users/johnw/src/nixos` (vulcan/NixOS) — service module, DNAT, VM registrations, monitoring, self-heal, ports.txt, host wiring
- `/Users/johnw/src/nix` (hera/darwin) — `authorized_keys` forced-command, optional launchd KeepAlive
- `/Users/johnw/src/promptdeploy` — `mcp/drafts-hera.yaml`, `mcp/drafts.yaml` comment
- `/etc/nixos/secrets` (third, independent git tree) — `secrets.yaml`

This spec is the implementation-ready successor to the approved design at `docs/superpowers/specs/2026-06-08-drafts-mcp-bridge-design.md`. Every file body and diff below was verified against the live repo files on 2026-06-09 (anchors are `path:line`). It applies all non-rejected adversarial-review fixes (notably the **9097→9085 port collision** fix and the **single merged filter-shim ExecStart**).

---

## 1. Goal

Let three consumers drive the **Drafts.app** MCP tools, where Drafts runs **only** on the macOS host **hera**:

1. **Host Claude Code** (`claude-vulcan`, on the vulcan *host*) — plain SSH-stdio to hera, **full** toolset (operator).
2. **OpenClaw** agentic microVM (`10.99.0.2`) — MCP-SSE through a host-side bridge, reached via the existing two-stage DNAT chain, **read-only** surface (write tools denied by a stdio filter shim).
3. **Hermes** agentic microVM (`10.99.1.2`) — same SSE bridge via `hermes-br0` DNAT, **default-deny allowlist** (no `drafts_run_action`, no destructive writes).

Deliverable: a host-side **`drafts-mcp.service`** on vulcan bridging a remote **stdio** MCP server on hera (`drafts-mcp-server`, already packaged) to an **SSE** endpoint on `127.0.0.1:9082`, plus the cross-repo wiring (SSH key authorization on hera, MCP registration in each consumer), monitoring, and probe-driven self-heal — preserving microVM egress isolation and giving autonomous agents a least-privilege, write-gated tool surface.

## 2. Non-goals

- **NOT** packaging a new long-lived FastMCP service like `hermes-mcp` — `drafts-mcp-server` is a complete 20-tool stdio server; only transport adaptation (mcp-proxy) + a thin stdio filter shim are needed.
- **NOT** widening guest egress beyond a single new loopback DNAT port (9082) per bridge.
- **NOT** giving the agentic VMs direct SSH/LAN access to hera.
- **NOT** porting the `hermes-mcp` 30 s progress-heartbeat or SQLite session store — Drafts ops are fast and stateless (`DynamicUser`, no `StateDirectory`).
- **NOT** building the launchd-Aqua TCC fallback — Phase-1 validation (§3) closed the TCC risk in favor of SSH-stdio. (The optional launchd KeepAlive agent in §9.6 is a *cold-Drafts* mitigation, orthogonal to the rejected TCC fallback.)

## 3. Topology + TCC-validated note

```
                     ┌──────────────────────── hera (macOS, johns-mac-studio) ───────────────────────┐
                     │  sshd ──(authorized_keys forced-command, key drafts-bridge@vulcan)──►          │
                     │            drafts-mcp-server  (stdio MCP, 20 tools)                             │
                     │                          │  osascript / AppleEvents                            │
                     │                          ▼                                                     │
                     │                       Drafts.app  (johnw's Aqua GUI session)                   │
                     └───────────────────────────▲──────────────────────────────────────────────────┘
                                                  │ SSH-stdio over LAN 192.168.1.0/24
                                                  │ (dedicated ed25519 key, BatchMode, PINNED known_hosts)
 ┌──────────────────────── vulcan (NixOS host, 192.168.1.2) ──┼─────────────────────────────────────┐
 │                                                            │                                      │
 │  claude-vulcan (host Claude Code) ── plain SSH-stdio ──────┘   (NO bridge; FULL toolset; operator)│
 │                                                                                                   │
 │  drafts-mcp.service (DynamicUser):                                                                │
 │    mcp-proxy 0.10.0 server mode  ──►  drafts-tool-filter (stdio shim)  ──►  single shared ssh child│
 │    binds 127.0.0.1:9082  (serves /sse + /mcp)        └─ strips 9 write tools for the VM endpoint ─┘│
 │            ▲                                                                                       │
 │  host PREROUTING DNAT  (br-openclaw 10.99.0.1:9082→127.0.0.1:9082;                                 │
 │                         hermes-br0 10.99.1.1:9082→127.0.0.1:9082)                                  │
 │            ▲                                                                                       │
 └────────────┼─────────────────────────────────────────────────────────────────────────────────────┘
              │ two-stage DNAT (guest OUTPUT 127.0.0.1:9082 → bridge gw → host PREROUTING → 127.0.0.1:9082)
      ┌───────┴────────┐                              ┌──────────────────┐
      │ OpenClaw VM    │ mcporter.json:               │ Hermes VM        │ services.hermes-agent.mcpServers:
      │ 10.99.0.2      │  "drafts-hera":{url:.../sse}  │ 10.99.1.2        │  drafts-hera={url=.../sse; tools.include=[…];}
      │  READ-ONLY     │  (shim strips writes)         │  default-deny    │  (10-tool allowlist; no run_action)
      └────────────────┘                              └──────────────────┘
```

> **TCC VALIDATED 2026-06-09 → SSH-stdio is GO; NO launchd-Aqua fallback** (design §6.3).
> Three representative tests passed with **zero** `-1743`/`isError`: (1) vulcan→hera fresh, non-multiplexed ssh-as-johnw running `osascript "count drafts"` → `125`; (2) loopback fresh sshd → `drafts-mcp-server` → node → osascript → clean `tools/call drafts_list_workspaces`; (3) gold-standard vulcan-origin fresh ssh → `drafts-mcp-server` → `drafts_get_drafts` → valid `"id":2`. Conclusion: the macOS Automation grant is **session-bound, not connection-bound**, and **origin-agnostic** — TCC only sees the hera-side johnw-via-sshd process, so a systemd `DynamicUser` + dedicated key initiating from vulcan is covered. **Still unverified (operational, non-blocking):** >1 h longevity; behaviour across johnw **logout** (logout tears down the Aqua session → grant lost, detected by `drafts_mcp_tcc_automation_ok`); the dedicated forced-command key end-to-end (Phase 2). hera never sleeps; screen-lock preserves the session.

## 4. Decisions summary (D1–D9 + locked open-question resolutions)

| # | Decision | Locked choice |
|---|---|---|
| D1 | Bridge endpoint transport | **MCP SSE** at `http://127.0.0.1:9082/sse` (mcp-proxy serves `/sse` + `/mcp`; matches the proven `hermes`@9081 shape). |
| D2 | Bridge tool | `pkgs.mcp-proxy` **0.10.0** server mode + a **stdio filter shim** (`writePython3Bin`) interposed before ssh. **SHIP THE SHIM** — sole OpenClaw enforcement point. |
| D3 | VM transport path | **New dedicated loopback DNAT port 9082** on both bridges; all four derived rule families auto-derive from `dnatPorts`. |
| D4 | SSH identity | **ssh as johnw**, dedicated **ed25519** key pinned by an `authorized_keys` **forced-command**. |
| D5 | Port number | **9082** (`127.0.0.1`). Re-verify free vs live `ss -ltnp` (plan task). |
| D6 | MCP server name | **`drafts-hera`** everywhere on vulcan (host entry + both VM registries). The Mac-local `mcp/drafts.yaml` stays `name: drafts`. promptdeploy `validate` dedups `(item_type,name)` globally → a second `drafts` fails the gate. |
| D7 | Write tools for autonomous VMs | ~~Deny all 9 write tools (incl. `drafts_run_action`) to BOTH VMs.~~ **SUPERSEDED 2026-06-10 — see the correction below.** OpenClaw: filter shim (hard). Hermes: `tools.include` allowlist (default-deny). Host CC: full toolset. |
| D8 | SSE vs streamable-HTTP | **SSE** for VMs; SSH-stdio (command-based) for host CC. |
| D9 | Lifecycle / recovery | Single shared ssh child + ssh `ConnectTimeout`/`ServerAlive*` + **health-probe-driven `systemctl restart drafts-mcp.service`** (a dead backend is a silent green zombie; `Restart=on-failure` is insufficient). |

> **D7 superseded (2026-06-10, owner decision, deployed in nixos-config `c60d21a`):** the agent VMs get the **full read/write draft surface** — the point of the bridge is that Hermes/OpenClaw can *make* drafts on request, not just read them. The enforcement *mechanisms* are unchanged; only the policy narrowed: the filter shim's `DENY` set shrinks from the nine `readOnlyHint:false` tools to exactly **`drafts_run_action`** (arbitrary Drafts action execution — including script actions — as johnw inside hera's GUI session is code execution, not draft management, and stays operator-only), and Hermes' `tools.include` expands to all 19 remaining tools (11 reads + 8 writes, still default-deny against future upstream additions). The embedded code blocks in §6/§8 below show the launch-era 9-tool deny set; the repo (`pkgs/drafts-tool-filter/default.nix`, `modules/services/hermes-vm.nix`, `modules/services/openclaw-vm.nix`) is canonical. Verified live 2026-06-10: bridge serves 19 tools, `drafts_run_action` stripped from `tools/list` and `isError`-denied on call, Hermes registered all 19 and created+tagged a real draft on request (read back by UUID through the bridge).

**Open-question resolutions — now LOCKED:**

| Q | Resolution |
|---|---|
| Q1 TCC outcome | **PASS** (design §6.3). SSH-stdio architecture, no launchd fallback. |
| Q2 OpenClaw enforcement | Ship the **filter shim** (D7). It correctly passes `initialize`/`notifications/*`/`ping` and filters only `tools/*`. |
| Q3 Concurrency | Single shared ssh serializes at Drafts (HOL-blocking **accepted**); add a host-side per-call deadline via ssh `ServerAlive*` + probe `RuntimeMaxSec`. |
| Q4 Cold Drafts | **Optional** hera launchd `KeepAlive` agent keeps Drafts resident (§9.6); ship only if cold-launch latency is observed. |
| Q5 Hermes allowlist | **`tools.include`** (default-deny) — denies future upstream tools by default. |
| Q6 Pinned known_hosts | **Pin** (fail closed); documented host-key-rotation runbook (§11). |
| Q7 Self-heal scope | **Probe-driven `systemctl restart` ONLY** — never a Drafts tool call. Orthogonal to `run_action`. |
| Q8 Port liveness | Re-verify **9082** (bridge) and **9085** (self-heal webhook) free vs live `ss -ltnp` before commit (plan task). |

---

## 5. Section A — `drafts-mcp.service` module + host wiring

This is the host-side bridge unit. Modeled on `stock-trader.nix` (`DynamicUser` + `LoadCredential` + `RuntimeDirectory` + writable HOME) and `hermes-mcp.nix` (hardening block, `after`/`wants`, sops `restartUnits`).

**Review fixes applied:**
- **MERGED ExecStart** — the single source of truth is the **filter-shim form** (`lib.escapeShellArgs`, with `draftsToolFilter` interposed before the ssh wrapper). The svc-module's competing no-shim `concatStringsSep` ExecStart is **deleted** (shipping it would silently remove OpenClaw's write-tool denial).
- **`StartLimitIntervalSec`/`StartLimitBurst` under `unitConfig`** (verified `litellm.nix:91-96`); placing them in `serviceConfig` is silently ignored.
- **`LoadCredential` id `hera-ssh-key`** matches the basename the wrapper hardcodes at `/run/credentials/drafts-mcp.service/hera-ssh-key` (a mismatch builds clean but fails at runtime with "no such identity").
  > **Correction (2026-06-10, deployed):** the wrapper must **NOT** use `"$CREDENTIALS_DIRECTORY/hera-ssh-key"` as originally specified. mcp-proxy spawns the stdio backend through the MCP Python SDK's `stdio_client`, which scrubs the child env down to `get_default_environment()`'s allowlist (`HOME`, `LOGNAME`, `PATH`, `SHELL`, `TERM`, `USER` on POSIX) — `$CREDENTIALS_DIRECTORY` is stripped, expands to `""`, ssh sees `-i /hera-ssh-key` → "Identity file not accessible" → publickey auth fails while the unit stays `active` (the silent-green-zombie failure mode, observed live 2026-06-09). The fix references the stable documented systemd path `/run/credentials/<unit>/` directly.
- **Build-time assertion** that `pinnedKnownHosts` does not contain `REPLACE_ME` — the `writeText` placeholder does **NOT** break the build by itself (verified: `writeText` with any string body evaluates fine); the failure would otherwise be runtime-only (StrictHostKeyChecking). The assertion makes `enable` fail closed at eval until the real Phase-1 host key lands.

### NEW FILE — `/Users/johnw/src/nixos/modules/services/drafts-mcp.nix`

```nix
# drafts-mcp: host-side SSE bridge to the Drafts.app MCP server on hera.
#
# Bridges a remote *stdio* MCP server (`drafts-mcp-server`, packaged on
# hera at /etc/profiles/per-user/johnw/bin/drafts-mcp-server) to a loopback
# *SSE* endpoint on 127.0.0.1:9082. mcp-proxy 0.10.0 runs in server mode and
# spawns ONE long-lived child for its entire lifetime: drafts-tool-filter,
# which in turn execs a single ssh child to hera. That ssh execs
# drafts-mcp-server via an authorized_keys forced-command (the remote command
# arg is intentionally omitted — the forced-command pins the binary and
# ignores SSH_ORIGINAL_COMMAND).
#
# OpenClaw (10.99.0.2) and Hermes (10.99.1.2) reach 127.0.0.1:9082 via the
# two-stage DNAT chain (openclaw-microvm.nix / hermes-microvm.nix dnatPorts).
# LAN hosts cannot reach it — the bind is loopback-only.
#
# Modeled on:
#   - modules/services/stock-trader.nix  (DynamicUser + LoadCredential +
#     RuntimeDirectory + writable HOME; stateless — no DB to own)
#   - modules/services/hermes-mcp.nix    (hardening block, after/wants,
#     sops restartUnits, RestrictAddressFamilies incl AF_INET)
#
# Recovery: a dead hera-side backend leaves mcp-proxy a silent green zombie
# (it catches the upstream error and keeps serving isError), so
# Restart=on-failure does NOT cover steady-state backend death. The
# load-bearing recovery is the health-probe-driven
# `systemctl restart drafts-mcp.service` in
# modules/services/drafts-mcp-self-heal.nix, driven by
# modules/monitoring/services/drafts-mcp-check.nix + alerts/drafts.yaml.
# Restart=on-failure + StartLimit here only handle hard crashes and bound
# boot crash-loops when hera is unreachable.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.drafts-mcp;

  # ---- PINNED hera host key ----
  # PHASE-1 PLACEHOLDER — REPLACE before enabling the service.
  # Capture on vulcan during Phase 1:
  #     ssh-keyscan -t ed25519 hera.lan
  # and paste the single resulting line below (format:
  # `hera.lan ssh-ed25519 AAAA...`). A store-path pin means a hera host-key
  # change (e.g. macOS reinstall) crash-loops the bridge until this file is
  # updated and rebuilt — that is intentional (fail closed). See the
  # host-key-rotation runbook (spec §11). NOTE: this placeholder does NOT
  # break the build on its own; the assertion below is what fails closed.
  pinnedKnownHosts = pkgs.writeText "drafts-mcp-known-hosts" ''
    REPLACE_ME_WITH_HERA_ED25519_HOST_KEY_FROM_PHASE_1
  '';

  pinnedPlaceholderPresent =
    lib.hasInfix "REPLACE_ME" (builtins.readFile pinnedKnownHosts);

  # Write-tool filter shim — the sole OpenClaw enforcement point. Imported
  # directly; no overlay/flake entry (pkgs/drafts-tool-filter).
  draftsToolFilter = import ../../pkgs/drafts-tool-filter { inherit pkgs; };

  # ---- ssh-stdio wrapper ----
  # The single ssh child (spawned by the filter shim). NO remote-command arg:
  # hera's authorized_keys forced-command execs drafts-mcp-server and ignores
  # SSH_ORIGINAL_COMMAND. The private key is read from the per-unit
  # credentials directory populated by LoadCredential.
  #   -T                       : no PTY (forced-command + clean stdio)
  #   IdentitiesOnly=yes       : use ONLY the -i key, ignore agent/defaults
  #   BatchMode=yes            : never prompt (fail fast in a unit)
  #   StrictHostKeyChecking=yes: refuse unknown/changed host keys
  #   UserKnownHostsFile=<pin> : trust ONLY the pinned hera key
  #   GlobalKnownHostsFile=/dev/null : ignore /etc/ssh known_hosts
  #   ConnectTimeout=10        : bound the TCP/auth handshake
  #   ServerAliveInterval=30 / ServerAliveCountMax=3 : detect a dead peer
  #                              within ~90s so the child exits (then the
  #                              probe-driven restart can recover).
  # CREDENTIAL PATH IS HARDCODED, NOT $CREDENTIALS_DIRECTORY: the MCP Python
  # SDK's stdio_client scrubs the child env to its default allowlist, which
  # drops $CREDENTIALS_DIRECTORY (see §"Review fixes applied"). We use the
  # stable systemd path /run/credentials/<unit>/ instead.
  sshWrapper = pkgs.writeShellScript "drafts-mcp-ssh" ''
    exec ${pkgs.openssh}/bin/ssh -T \
      -i /run/credentials/drafts-mcp.service/hera-ssh-key \
      -o IdentitiesOnly=yes \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile=${pinnedKnownHosts} \
      -o GlobalKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      johnw@hera.lan
  '';
in
{
  options.services.drafts-mcp = {
    enable = lib.mkEnableOption "the drafts-mcp Drafts.app(hera) SSE bridge";

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Bind address for the SSE endpoint. The default 127.0.0.1 keeps the
        bridge unreachable from the LAN; OpenClaw and Hermes microVMs reach it
        via the two-stage DNAT chain (openclaw-microvm.nix / hermes-microvm.nix).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9082;
      description = ''
        TCP port for the SSE endpoint. 9082 is recorded as a single loopback
        line in docs/ports.txt; re-verify it is free against a live `ss -ltnp`
        on vulcan before first switch.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Fail closed at eval until the real Phase-1 hera host key replaces the
    # placeholder. (writeText with the placeholder body builds fine on its
    # own, so without this assertion the service would build and then
    # crash-loop on StrictHostKeyChecking at runtime.)
    assertions = [
      {
        assertion = !pinnedPlaceholderPresent;
        message = ''
          services.drafts-mcp.enable is true but the pinned hera known_hosts
          in modules/services/drafts-mcp.nix still contains the REPLACE_ME
          placeholder. Capture the real key with
          `ssh-keyscan -t ed25519 hera.lan` and paste it into pinnedKnownHosts
          before enabling (land it in the SAME commit as the enable flag).
        '';
      }
    ];

    # Dedicated ed25519 private key authorizing the forced-command on hera.
    # mode 0400 owner/group root: DynamicUser reads it indirectly via
    # LoadCredential (systemd copies it into the per-unit credential dir as
    # root, before the user switch). restartUnits cuts the service onto a
    # rotated key on rebuild.
    sops.secrets."drafts/hera-ssh-private-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "drafts-mcp.service" ];
    };

    systemd.services.drafts-mcp = {
      description = "Drafts.app (hera) MCP SSE bridge";
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        # Bound boot crash-loops if hera is unreachable. Verified shape:
        # litellm.nix:91-96 puts these under unitConfig (NOT serviceConfig).
        StartLimitIntervalSec = "300";
        StartLimitBurst = "5";
      };

      environment = {
        # ProtectHome=true makes /home unavailable; ssh still wants a writable
        # HOME for ~/.ssh scratch. %t = the runtime root (/run); point HOME at
        # the private RuntimeDirectory so ssh never hits a read-only-home error.
        HOME = "%t/drafts-mcp";
      };

      serviceConfig = {
        Type = "exec";

        # Server mode: bind the SSE listener on loopback, spawn the filter
        # shim, which spawns the single ssh child. NO --transport (a
        # client-only no-op; server mode mounts /sse + /mcp unconditionally).
        # The shim denies the 9 write tools (incl. drafts_run_action) on this
        # VM-facing SSE endpoint — it is the SOLE OpenClaw enforcement point.
        #
        # Chain: mcp-proxy ─► drafts-tool-filter ─► ssh johnw@hera.lan
        #        ─(forced-command)► drafts-mcp-server ─osascript► Drafts.app
        ExecStart = lib.escapeShellArgs [
          "${pkgs.mcp-proxy}/bin/mcp-proxy"
          "--host"
          cfg.host
          "--port"
          (toString cfg.port)
          "--"
          "${draftsToolFilter}/bin/drafts-tool-filter"
          "${sshWrapper}"
        ];

        # A dead backend is a silent zombie; on-failure only catches hard
        # crashes (probe-driven restart is the real recovery). ~30s avoids
        # tight boot crash-loops against a transiently-down hera.
        Restart = "on-failure";
        RestartSec = "30s";

        DynamicUser = true;

        # Private, writable HOME for ssh under /run (tmpfs). No StateDirectory
        # — the bridge is stateless.
        RuntimeDirectory = "drafts-mcp";
        RuntimeDirectoryMode = "0700";

        # Dedicated ssh private key, read-only in the unit namespace. The id
        # `hera-ssh-key` MUST match the basename the wrapper hardcodes at
        # /run/credentials/drafts-mcp.service/hera-ssh-key.
        LoadCredential = [
          "hera-ssh-key:${config.sops.secrets."drafts/hera-ssh-private-key".path}"
        ];

        # Hardening — cloned from hermes-mcp.nix:166-187 / stock-trader.nix:222-247.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        # ssh dials hera over the LAN — AF_INET is required.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        # mcp-proxy + the shim are Python (CPython needs W^X off).
        MemoryDenyWriteExecute = false;

        MemoryMax = "256M";
      };
    };
  };
}
```

### EDIT 1 — `/Users/johnw/src/nixos/hosts/vulcan/default.nix` (import)

Anchor: the `hermes-mcp.nix` import at `:152`. Insert the new import immediately after it.

**Before (`hosts/vulcan/default.nix:151-153`):**
```nix
    ../../modules/services/hermes-microvm.nix
    ../../modules/services/hermes-mcp.nix
    ../../modules/services/hermes-self-heal.nix
```

**After:**
```nix
    ../../modules/services/hermes-microvm.nix
    ../../modules/services/hermes-mcp.nix
    ../../modules/services/drafts-mcp.nix
    ../../modules/services/drafts-mcp-self-heal.nix
    ../../modules/services/hermes-self-heal.nix
```

### EDIT 2 — `/Users/johnw/src/nixos/hosts/vulcan/default.nix` (enable flags)

Anchor: `services.hermes-mcp.enable` at `:192` and the self-heal flags at `:194-195`.

**Before (`hosts/vulcan/default.nix:191-195`):**
```nix
  services.stock-trader.enable = true;
  services.hermes-mcp.enable = true;
  services.hermesHealthCheck.enable = true;
  services.hermesSelfHeal.enable = true;
  services.openclawSelfHeal.enable = true;
```

**After:**
```nix
  services.stock-trader.enable = true;
  services.hermes-mcp.enable = true;
  services.drafts-mcp.enable = true;
  services.hermesHealthCheck.enable = true;
  services.draftsMcpCheck.enable = true;
  services.hermesSelfHeal.enable = true;
  services.openclawSelfHeal.enable = true;
  services.draftsMcpSelfHeal.enable = true;
```

> `services.draftsMcpCheck.enable` and `services.draftsMcpSelfHeal.enable` are defined in §9 (monitoring). The monitoring-check module is imported via `modules/monitoring/services/default.nix` (§9 Edit); the self-heal module is imported in EDIT 1 above.

---

## 6. Section B — OpenClaw write-tool filter shim

**The SOLE OpenClaw enforcement point** (mcporter has no per-server tool filter; mcp-proxy is transparent). A transparent MCP **stdio** middleman: it execs the ssh wrapper passed as argv, pumps full-duplex, and rewrites JSON-RPC only where policy requires.

**Review fixes applied:**
- **Fail CLOSED on the up-pump (client→child) parse-failure path** (security fix): an unparseable line from the client is **dropped**, not forwarded verbatim to ssh→drafts-mcp-server. The down-pump (child→client) keeps verbatim pass-through.
- The 9-tool deny set is exactly the `readOnlyHint:false` set (verified line-by-line in the built v1.0.12 `dist/index.js`).
- `tools/call` deny is the security boundary (a client can call a tool it never listed); `tools/list` strip is discovery hygiene. **Both** implemented.
- Notifications/`initialize`/`ping`/batch arrays pass through; the synthesized deny **result** echoes the verbatim `id` (string|number|null) and uses `result.isError:true` (MCP tool-error envelope, not a JSON-RPC error object).

> **Testability note (review medium):** the shim convention in-repo is `builtins.readFile ../../scripts/<name>.py` (e.g. `hermes_fallback_counter.py`). The inline heredoc below builds (verified: no `${` antiquotation collision — only Python str-concat and dict literals), but is not pytest-importable. **Recommended (do during Phase 2):** extract `is_denied_call`/`strip_tools_list`/`deny_result` into `scripts/drafts_tool_filter.py`, `builtins.readFile` it (note `pkgs/` depth is `../../scripts`, not `../../../scripts`), and add the pytest in §6.3 + a NixOS-VM integration test piping a denied `tools/call` (string id + batch) through the built binary asserting `isError` without the child seeing it.

### NEW FILE — `/Users/johnw/src/nixos/pkgs/drafts-tool-filter/default.nix`

```nix
# pkgs/drafts-tool-filter/default.nix
#
# Transparent MCP *stdio* filter shim. Spawns the real MCP child (passed as
# argv, e.g. the drafts ssh wrapper), pumps bytes both ways, and rewrites
# JSON-RPC ONLY where policy requires:
#
#   (a) tools/list RESULTS from the child  -> strip the 9 Drafts write tools
#       from .result.tools (discovery hygiene).
#   (b) tools/call REQUESTS to the child whose .params.name is in the deny
#       set -> DO NOT forward; synthesize a JSON-RPC result with isError:true
#       + a policy message, echoing the original id. (Load-bearing security
#       boundary: a client can call a tool it never listed.)
#   (c) initialize, notifications/*, ping, batch arrays, and all other valid
#       traffic -> pass verbatim.
#   (d) UNPARSEABLE client->child lines -> DROP (fail closed). The reverse
#       direction (child->client) passes unparseable lines verbatim.
#
# This is the ONLY write-tool enforcement point for OpenClaw (mcporter has no
# per-server tool filter; mcp-proxy is transparent). Hermes is gated by a
# tools.include allowlist at registration; host operator (claude-vulcan)
# bypasses the bridge and gets the full toolset.
#
# Deny set verified against drafts-mcp-server v1.0.12 dist/index.js: exactly
# the nine readOnlyHint:false tools.
#
# No overlay / flake entry: callers do
#   `import ../../pkgs/drafts-tool-filter { inherit pkgs; }`.
{ pkgs }:

pkgs.writers.writePython3Bin "drafts-tool-filter"
  {
    flakeIgnore = [
      "E501" # long lines (deny-set literals, log strings)
      "W503" # line break before binary operator
      "E203" # whitespace before ':' (black-compatible)
    ];
  }
  ''
    """Transparent MCP stdio filter for the Drafts bridge.

    Frames JSON-RPC on newlines (the MCP stdio transport contract),
    tolerates partial reads, supports concurrent in-flight ids, and is
    full-duplex (separate threads per direction).
    """
    import json
    import sys
    import threading
    import subprocess

    # The nine readOnlyHint:false Drafts tools (v1.0.12). Denied to the
    # autonomous OpenClaw VM. drafts_run_action is code-exec as johnw on hera,
    # so it is the single most important entry.
    DENY = frozenset({
        "drafts_create_draft",
        "drafts_update_draft",
        "drafts_add_tags",
        "drafts_flag",
        "drafts_archive",
        "drafts_inbox",
        "drafts_trash",
        "drafts_open_workspace",
        "drafts_run_action",
    })

    POLICY_MSG = (
        "Tool denied by the drafts-mcp bridge policy: write/action tools "
        "(including drafts_run_action) are not available to autonomous agents "
        "on this endpoint. Read-only Drafts tools only."
    )


    def log(msg):
        # stderr is inherited by the systemd unit -> journal. Never write to
        # stdout (that is the MCP channel).
        sys.stderr.write("drafts-tool-filter: " + msg + "\n")
        sys.stderr.flush()


    def deny_result(req_id):
        """A JSON-RPC *result* carrying an MCP tool result with isError:true.
        MCP clients surface this to the model as a failed tool call rather than
        a protocol error, which is the behaviour we want."""
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "content": [{"type": "text", "text": POLICY_MSG}],
                "isError": True,
            },
        }


    def is_denied_call(msg):
        if not isinstance(msg, dict):
            return False
        if msg.get("method") != "tools/call":
            return False
        params = msg.get("params")
        if not isinstance(params, dict):
            return False
        return params.get("name") in DENY


    def strip_tools_list(msg):
        """If this is a tools/list RESULT, drop denied tools from
        .result.tools. Returns the (possibly mutated) message."""
        if not isinstance(msg, dict):
            return msg
        result = msg.get("result")
        if not isinstance(result, dict):
            return msg
        tools = result.get("tools")
        if not isinstance(tools, list):
            return msg
        kept = [
            t for t in tools
            if not (isinstance(t, dict) and t.get("name") in DENY)
        ]
        if len(kept) != len(tools):
            result["tools"] = kept
        return msg


    def pump_client_to_child(client_in, child_out, denied_out, lock):
        """stdin (from mcp-proxy) -> child stdin. Intercept denied tools/call
        and short-circuit a synthetic result back out our OWN stdout
        (denied_out) instead of forwarding. UNPARSEABLE lines are DROPPED
        (fail closed) — never forwarded raw to ssh->drafts-mcp-server."""
        for raw in client_in:
            line = raw.rstrip(b"\n")
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                # Security boundary: a line we cannot parse must NOT be
                # forwarded to the child (it could be a denied tools/call we
                # failed to inspect). Drop and log.
                log("dropped unparseable client->child line (fail closed)")
                continue

            # Batch (array): filter element-wise; forward non-denied, answer
            # denied ones ourselves.
            if isinstance(msg, list):
                forward = []
                replies = []
                for el in msg:
                    if is_denied_call(el):
                        replies.append(deny_result(
                            el.get("id") if isinstance(el, dict) else None))
                    else:
                        forward.append(el)
                if forward:
                    child_out.write(
                        (json.dumps(forward) + "\n").encode("utf-8"))
                    child_out.flush()
                for r in replies:
                    with lock:
                        denied_out.write(
                            (json.dumps(r) + "\n").encode("utf-8"))
                        denied_out.flush()
                continue

            if is_denied_call(msg):
                rid = msg.get("id")
                name = msg.get("params", {}).get("name")
                log("denied tools/call name=" + repr(name)
                    + " id=" + repr(rid))
                with lock:
                    denied_out.write(
                        (json.dumps(deny_result(rid)) + "\n").encode("utf-8"))
                    denied_out.flush()
                continue

            # Everything else (initialize, tools/list req, ping,
            # notifications/*, read tool calls) -> verbatim.
            child_out.write(raw)
            child_out.flush()
        try:
            child_out.close()
        except OSError:
            pass


    def pump_child_to_client(child_in, client_out, lock):
        """child stdout -> our stdout (to mcp-proxy). Strip denied tools from
        tools/list results; everything else verbatim. Held under the same lock
        as denied replies so interleaved writes never tear a line."""
        for raw in child_in:
            line = raw.rstrip(b"\n")
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                with lock:
                    client_out.write(raw)
                    client_out.flush()
                continue

            if isinstance(msg, list):
                out = json.dumps([strip_tools_list(el) for el in msg])
            else:
                out = json.dumps(strip_tools_list(msg))
            with lock:
                client_out.write((out + "\n").encode("utf-8"))
                client_out.flush()


    def main():
        argv = sys.argv[1:]
        if not argv:
            log("usage: drafts-tool-filter <child-cmd> [args...]")
            return 2

        child = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=None,            # child stderr -> our stderr -> journal
            bufsize=0,
        )

        # One lock serialises ALL writes to our stdout (denied replies from the
        # up-pump AND stripped results from the down-pump) so concurrent
        # in-flight ids never interleave a half-line.
        out_lock = threading.Lock()
        stdout_buf = sys.stdout.buffer
        stdin_buf = sys.stdin.buffer

        t_down = threading.Thread(
            target=pump_child_to_client,
            args=(child.stdout, stdout_buf, out_lock),
            daemon=True,
        )
        t_down.start()

        # Up-pump in the main thread; when client stdin closes it closes the
        # child's stdin, the child exits, the down-pump iterator ends, we reap.
        pump_client_to_child(
            iter(stdin_buf.readline, b""),
            child.stdin,
            stdout_buf,
            out_lock,
        )

        rc = child.wait()
        t_down.join(timeout=5)
        return rc


    if __name__ == "__main__":
        sys.exit(main())
  ''
```

> The shim and ssh wrapper are wired into `drafts-mcp.nix`'s ExecStart (§5) — `lib.escapeShellArgs [ mcp-proxy "--host" host "--port" port "--" filter sshWrapper ]`. mcp-proxy execs `drafts-tool-filter <sshWrapper-path>`; the shim execs `<sshWrapper-path>` (which execs ssh). There is exactly ONE ExecStart in the module — no competing form.

### 6.3 Unit-test sketch (pytest) — apply after extracting `scripts/drafts_tool_filter.py`

```python
# tests/drafts_tool_filter/test_policy.py
import pytest
from drafts_tool_filter import DENY, is_denied_call, strip_tools_list, deny_result

NINE_WRITE = {
    "drafts_create_draft", "drafts_update_draft", "drafts_add_tags",
    "drafts_flag", "drafts_archive", "drafts_inbox", "drafts_trash",
    "drafts_open_workspace", "drafts_run_action",
}
ELEVEN_READ = {
    "drafts_list_workspaces", "drafts_list_tags", "drafts_get_tag",
    "drafts_get_current_workspace", "drafts_get_current",
    "drafts_get_workspace_drafts", "drafts_get_drafts", "drafts_get_draft",
    "drafts_search", "drafts_list_actions", "drafts_open",
}


def test_deny_set_is_exactly_the_nine_write_tools():
    assert DENY == NINE_WRITE


@pytest.mark.parametrize("name", sorted(NINE_WRITE))
def test_denied_call_is_blocked(name):
    msg = {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
           "params": {"name": name, "arguments": {}}}
    assert is_denied_call(msg) is True


@pytest.mark.parametrize("name", sorted(ELEVEN_READ))
def test_read_call_passes(name):
    msg = {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
           "params": {"name": name, "arguments": {}}}
    assert is_denied_call(msg) is False


def test_deny_result_echoes_string_numeric_and_null_id():
    assert deny_result("abc")["id"] == "abc"
    assert deny_result(42)["id"] == 42
    assert deny_result(None)["id"] is None
    r = deny_result("abc")
    assert r["jsonrpc"] == "2.0" and r["result"]["isError"] is True
    assert "denied" in r["result"]["content"][0]["text"].lower()


def test_strip_removes_only_write_tools_from_tools_list():
    tools = [{"name": n} for n in sorted(NINE_WRITE | ELEVEN_READ)]
    out = strip_tools_list({"jsonrpc": "2.0", "id": 1, "result": {"tools": tools}})
    names = {t["name"] for t in out["result"]["tools"]}
    assert names == ELEVEN_READ and len(out["result"]["tools"]) == 11


def test_notifications_and_ping_pass_through():
    for m in (
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 1, "method": "ping"},
        {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}},
    ):
        assert is_denied_call(m) is False
        assert strip_tools_list(dict(m)) == m
```

---

## 7. Section C — DNAT port 9082 on both bridges + ports.txt

Adding `9082` to each bridge's `dnatPorts` is the **complete** network edit; all four derived nft/iptables rule families (guest OUTPUT DNAT, host PREROUTING, INPUT allow, isolate RETURN) auto-derive from `dnatPorts`/`dnatPortList`.

### EDIT 1 — `/Users/johnw/src/nixos/modules/services/openclaw-microvm.nix`

Anchor: `9081` is the last element at `:137`; closing `];` at `:138`. **Do NOT touch the `", "` (WITH-space) join at `:141`.**

**Before (`:136-138`):**
```nix
    8123 # Home Assistant (direct HTTP)
    9081 # hermes-mcp — OpenClaw↔Hermes MCP bridge (SSE)
  ];
```

**After:**
```nix
    8123 # Home Assistant (direct HTTP)
    9081 # hermes-mcp — OpenClaw↔Hermes MCP bridge (SSE)
    9082 # drafts-mcp — OpenClaw→Drafts(hera) SSE bridge (read-only surface; writes gated by the bridge filter shim)
  ];
```

**Optional assertion** (parity with the existing `builtins.elem` block). Insert immediately after the `2525` assertion (which ends at `:359`, before the `qdrant/api-key` assertion at `:360`):

```nix
    {
      assertion = builtins.elem 2525 dnatPorts;
      message = "OpenClaw DNAT ports must include 2525 (Postfix SMTP)";
    }
    {
      assertion = builtins.elem 9082 dnatPorts;
      message = "OpenClaw DNAT ports must include 9082 (drafts-mcp SSE bridge → Drafts on hera)";
    }
    {
      assertion = config.sops.secrets ? "qdrant/api-key";
```

### EDIT 2 — `/Users/johnw/src/nixos/modules/services/hermes-microvm.nix`

Anchor: bare integers; `8123` is the last element at `:70`; closing `];` at `:71`. **Do NOT alter the NO-SPACE `concatStringsSep ","` join at `:78`** (it feeds `iptables -m multiport --dports`, which rejects spaces). Hermes `dnatPorts` has **no** `assert builtins.elem` block, so no assertion edit.

**Before (`:69-71`):**
```nix
    5432
    8123
  ];
```

**After:**
```nix
    5432
    8123
    9082
  ];
```

### EDIT 3 — `/Users/johnw/src/nixos/docs/ports.txt`

Anchor: the `# microVM Bridge Services` block at `:124`; insert after the `openclaw-hermes-smoke` line at `:126`. Single `127.0.0.1` loopback line (no `10.99.x.1` mirror lines — matches the 9081 precedent).

**Before (`:124-127`):**
```
# microVM Bridge Services
9081 127.0.0.1 hermes-mcp (OpenClaw↔Hermes MCP bridge; OpenClaw VM reaches via br-openclaw DNAT 10.99.0.1:9081→127.0.0.1:9081)
9081 127.0.0.1 openclaw-hermes-smoke (15-min synthetic ask_hermes probe; second loopback consumer of the same bridge port)
18789 10.99.0.2 OpenClaw AI Gateway (microVM, proxied by nginx)
```

**After:**
```
# microVM Bridge Services
9081 127.0.0.1 hermes-mcp (OpenClaw↔Hermes MCP bridge; OpenClaw VM reaches via br-openclaw DNAT 10.99.0.1:9081→127.0.0.1:9081)
9081 127.0.0.1 openclaw-hermes-smoke (15-min synthetic ask_hermes probe; second loopback consumer of the same bridge port)
9082 127.0.0.1 drafts-mcp (Drafts(hera) MCP SSE bridge; OpenClaw via br-openclaw 10.99.0.1:9082→127.0.0.1:9082 and Hermes via hermes-br0 10.99.1.1:9082→127.0.0.1:9082)
18789 10.99.0.2 OpenClaw AI Gateway (microVM, proxied by nginx)
```

> The self-heal webhook line (`9085 127.0.0.1 drafts-mcp-self-heal …`) is added under the `# Self-heal …`/9090-band section of ports.txt — see §9.7.

---

## 8. Section D — VM registrations (OpenClaw mcporter + Hermes mcpServers)

**Review fix applied:** the OpenClaw mcporter `description` is **READ-ONLY** (design §7's write-advertising description contradicts D7; the shim strips writes, so advertising them would cause wasted denied calls).

`tests/openclaw/expected-keys.txt` needs **NO CHANGE** — it snapshots the guarded `openclaw-config-template` (`check-schema.nix:14-22`), not the runtime `mcporter.json` (injected in preStart, outside the template). Confirm with `grep -c mcpServers tests/openclaw/expected-keys.txt` → 0.

### EDIT 1 — `/Users/johnw/src/nixos/modules/services/openclaw-vm.nix`

Anchor: `:861-862` (the sole `drafts` reference; 14-space indent). Replace the `del()` with an add.

**Before (`openclaw-vm.nix:861-862`):**
```sh
              # Drafts (removed 2026-05-18 — hera-side server retired)
              apply_mcporter_jq 'del(.mcpServers["drafts"])'
```

**After (14-space indent; mirrors the `hermes` SSE entry):**
```sh
              # Drafts on hera via the host drafts-mcp SSE bridge (re-added
              # 2026-06; binds 127.0.0.1:9082, reached over the guest OUTPUT
              # DNAT 127.0.0.1:9082 → 10.99.0.1:9082 → host PREROUTING →
              # 127.0.0.1:9082, same loopback pattern as the hermes entry).
              # The bridge's stdio filter shim is the SOLE enforcement point
              # for this autonomous VM: it strips all 9 write tools (incl.
              # drafts_run_action) from tools/list and rejects them on
              # tools/call, so the description states the read-only surface
              # honestly (advertising writes would cause wasted denied calls).
              apply_mcporter_jq '
                .mcpServers["drafts-hera"] = {
                  "url": "http://127.0.0.1:9082/sse",
                  "description": "Drafts.app (macOS, on hera) via the host drafts-mcp SSE bridge. READ-ONLY surface: list/search/get drafts, tags, workspaces, and actions (drafts_search, drafts_get_draft, drafts_get_drafts, drafts_get_draft, drafts_get_current, drafts_get_current_workspace, drafts_get_workspace_drafts, drafts_list_tags, drafts_get_tag, drafts_list_workspaces, drafts_list_actions, drafts_open). All write tools — including drafts_run_action — are NOT available here; the bridge filters them out."
                }
              '
```

### EDIT 2 — `/Users/johnw/src/nixos/modules/services/hermes-vm.nix`

Anchor: `mcpServers = {` opens at `:669`; the `org-db` entry closes at `:749`; the block closes at `:750` (`    };`). Insert after `org-db`, before the block close. 6-space entry indent. **NO `description` field** (the submodule rejects it — `:660-668` NOTE).

**Before (`hermes-vm.nix:746-750`):**
```nix
      org-db = {
        command = "${orgDbMcpServer}";
        args = [ ];
      };
    };
```

**After:**
```nix
      org-db = {
        command = "${orgDbMcpServer}";
        args = [ ];
      };

      # Drafts.app on hera via the host drafts-mcp SSE bridge (binds
      # 127.0.0.1:9082; reached over the hermes-br0 guest OUTPUT DNAT
      # 127.0.0.1:9082 → 10.99.1.1:9082 → host PREROUTING → 127.0.0.1:9082).
      # This is the autonomous Hermes agent, so writes are denied twice over:
      # the bridge's stdio filter shim strips all 9 write tools server-side
      # for EVERY consumer, and this `include` allowlist (default-deny) is
      # the client-side belt-and-suspenders. drafts_run_action (code-exec
      # as johnw on hera) and all write tools are intentionally absent.
      # NO `description` field — the upstream mcpServers submodule
      # (see the NOTE at the top of this block) rejects it.
      #
      # URL is /mcp/ (Streamable HTTP), NOT /sse: hermes-agent's mcp_tool
      # speaks Streamable HTTP for `url` entries and the submodule exposes
      # no transport knob; mcp-proxy 0.8.2 mounts Streamable HTTP at /mcp/
      # — TRAILING SLASH REQUIRED (bare /mcp is a 404, no redirect).
      drafts-hera = {
        url = "http://127.0.0.1:9082/mcp/";
        connect_timeout = 10;
        timeout = 60;
        tools.include = [
          "drafts_search"
          "drafts_get_draft"
          "drafts_get_drafts"
          "drafts_list_tags"
          "drafts_list_workspaces"
          "drafts_get_current"
          "drafts_list_actions"
        ];
      };
    };
```

> **As-built corrections (2026-06-10, deployed):** two parts of the original EDIT 2 were invalidated during Phase 3.
> 1. **URL/transport:** the original `url = ".../sse"` assumed hermes-agent would speak SSE. It speaks **Streamable HTTP** for `url` entries (its `mcp_tool` POSTs JSON-RPC to the URL itself; observed live as `POST /sse → 405` ×4 then give-up, from `10.99.1.2` — which at least proved the two-stage DNAT path end-to-end). hermes-agent 0.15.x does support `transport: sse` in its own config.yaml, but the pinned nixosModules submodule exposes no such option, so the declarative fix is mcp-proxy 0.8.2's Streamable HTTP mount: `http://127.0.0.1:9082/mcp/` (trailing slash required; bare `/mcp` 404s). Verified: a full initialize → tools/list handshake over `/mcp/` returns the filtered 11-tool surface.
> 2. **Allowlist trimmed to 7 reads, no writes:** the original "7 reads + 3 benign writes" and the "Hermes leg is NOT shimmed" premise were wrong as built — there is ONE bridge endpoint and the `drafts-tool-filter` shim sits in its stdio chain for every consumer, so `create_draft`/`update_draft`/`add_tags` would be server-denied regardless of the client allowlist. Listing them would only invite wasted denied calls. If Hermes should ever get those writes, stand up a second, unfiltered bridge instance on its own port and point only Hermes at it.
>
> **Phase-3 gate (security-review medium), unchanged:** prove `tools.include` is enforcing default-deny by attempting a `tools/call drafts_run_action` from inside the Hermes VM and confirming it is *refused client-side* (not merely absent from `tools/list`).

---

## 9. Section E — Monitoring & self-heal

All probes are **loopback-SSE-only** and **read-only** (never `run_action`). Three findings from the review change the design:

- **M1** — the self-heal action CANNOT reuse the hermes harness (it is hermes-keyed: `ACTION_MAP` on hermes alert names, reads `hermes_health.prom`, runs as `hermes-heal` with a hermes-only sudoers allowlist, ignores unknown alerts). A dedicated minimal `drafts-mcp-self-heal` webhook receiver is required.
- **M2** — `self_heal_eligible="true"` is **documentary**, not a routing key. Alertmanager routes on `service=`. So `DraftsMcp*` alerts carry **`service: drafts-mcp`**, and a new route `match { service = "drafts-mcp"; }` → `receiver = "drafts-mcp-self-heal"` is added.
- **M3** — the probe needs **NO credentials**. It speaks MCP over loopback SSE only and infers ssh-vs-TCC health from the tool-call result envelope shape (transport break = no JSON-RPC result; lost grant = `isError`/`-1743`). Runs as a confined `DynamicUser` writing only to the world-writable (`1777`, `system-exporters.nix:60`) textfile dir.

**Port fix (BOTH reviewers, BLOCKING):** the design's `9097` self-heal port **collides with MailArchiver** (`docs/ports.txt:105`, `mailarchiver.nix:43`). **Use `9085`** — verified free (zero in-tree refs; not in the active ports.txt band; `9099` is Cockpit, `9095` is in the "previously seen, verify before reuse" comment block).

### 9.1 NEW FILE — `/Users/johnw/src/nixos/modules/monitoring/services/drafts-mcp-check.nix`

```nix
# Drafts MCP bridge end-to-end health check.
#
# Probes the host-side drafts-mcp.service (mcp-proxy 0.10.0 SSE on
# 127.0.0.1:9082) the way an OpenClaw/Hermes guest would, then drives ONE
# read-only Drafts tool over the bridge to prove the full chain:
#
#     vulcan drafts-mcp.service ─ssh─► hera sshd ─forced-command─►
#       drafts-mcp-server ─osascript/AppleEvents─► Drafts.app (johnw Aqua)
#
# Six metrics, all derived from loopback-SSE MCP traffic — the check holds NO
# ssh credential (the bridge owns the key). It infers transport vs. grant
# health from the tool-call result envelope:
#
#   * drafts_mcp_bridge_up              systemd unit active
#   * drafts_mcp_sse_open_ok            /sse accepts the connection + endpoint
#   * drafts_mcp_ssh_hera_ok            tools/list returned (ssh child + hera
#                                       server answered MCP)
#   * drafts_mcp_tcc_automation_ok      a READ-ONLY tools/call returned a
#                                       NON-error result (Drafts grant intact).
#                                       ssh_ok=1 ∧ tcc_ok=0 == lost Automation
#                                       grant (johnw logout) — NEVER run_action.
#   * drafts_mcp_e2e_ok                 the full chain (sse∧ssh∧tcc)
#   * drafts_mcp_check_last_run_timestamp_seconds
#
# CRITICAL: ONLY read-only tools (drafts_list_workspaces). NEVER a write tool,
# above all NEVER drafts_run_action. Recovery is an EXTERNAL
# `systemctl restart drafts-mcp.service` driven by alerts/drafts.yaml + the
# drafts-mcp-self-heal receiver — the probe takes no remediation.
#
# Emits /var/lib/prometheus-node-exporter-textfiles/drafts_mcp.prom.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.draftsMcpCheck;
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  healthScript = pkgs.writeScript "drafts-mcp-check.py" ''
    #!${
      pkgs.python3.withPackages (ps: with ps; [ httpx ])
    }/bin/python3
    """End-to-end drafts-mcp bridge probe -> Prometheus textfile.

    Read-only by construction: the single tools/call is
    drafts_list_workspaces (readOnlyHint: true). run_action and every write
    tool are never invoked. All probes have hard timeouts so the unit cannot
    hang past RuntimeMaxSec.
    """
    from __future__ import annotations

    import asyncio
    import json
    import os
    import pathlib
    import subprocess
    import time

    import httpx

    DRAFTS_MCP_SSE_URL = os.environ.get(
        "DRAFTS_MCP_SSE_URL", "http://127.0.0.1:9082/sse"
    )
    DRAFTS_MCP_UNIT = os.environ.get("DRAFTS_MCP_UNIT", "drafts-mcp.service")
    OUT_FINAL = pathlib.Path("${textfileDir}/drafts_mcp.prom")
    OUT_TMP = OUT_FINAL.with_suffix(".prom.tmp")

    SSE_OPEN_BUDGET_S = 5.0
    E2E_BUDGET_S = 45.0

    PROBE_TOOL = "drafts_list_workspaces"
    PROBE_ARGS: dict = {}


    def unit_is_active(unit: str) -> int:
        try:
            out = subprocess.run(
                ["${pkgs.systemd}/bin/systemctl", "is-active", unit],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
            return 1 if out == "active" else 0
        except Exception:
            return 0


    async def probe_sse_open() -> int:
        try:
            async with httpx.AsyncClient(timeout=SSE_OPEN_BUDGET_S) as c:
                async with c.stream("GET", DRAFTS_MCP_SSE_URL) as r:
                    if r.status_code != 200:
                        return 0
                    async for line in r.aiter_lines():
                        if line.startswith("data:") and "session_id=" in line:
                            return 1
            return 0
        except Exception:
            return 0


    def _is_tcc_failure(result_obj: dict) -> bool:
        """True if a tools/call result envelope looks like a hera-side TCC /
        AppleEvents grant failure. Any isError envelope counts (ssh already
        succeeded to return a JSON-RPC result). Also matches -1743 /
        'not authorized' in plain text content."""
        if result_obj.get("isError") is True:
            return True
        content = result_obj.get("content") or []
        text = " ".join(
            b.get("text", "") for b in content if b.get("type") == "text"
        ).lower()
        return ("-1743" in text) or ("not authorized" in text)


    async def probe_e2e() -> tuple[int, int, int]:
        """Open SSE -> init -> list -> ONE read-only tools/call.
        Returns (ssh_hera_ok, tcc_automation_ok, e2e_ok)."""
        ssh_ok = 0
        tcc_ok = 0
        try:
            async with httpx.AsyncClient(timeout=E2E_BUDGET_S) as c:
                async with c.stream("GET", DRAFTS_MCP_SSE_URL) as r:
                    if r.status_code != 200:
                        return (0, 0, 0)
                    lines = r.aiter_lines()
                    endpoint = None
                    async for line in lines:
                        if line.startswith("data:") and "/messages/" in line:
                            endpoint = line[len("data:"):].strip()
                            break
                    if not endpoint:
                        return (0, 0, 0)

                    base = DRAFTS_MCP_SSE_URL.rsplit("/sse", 1)[0]
                    post_url = f"{base}{endpoint}"

                    async def post(payload):
                        resp = await c.post(
                            post_url, json=payload,
                            headers={"Accept": "application/json, text/event-stream"},
                        )
                        resp.raise_for_status()

                    async def next_event():
                        async for line in lines:
                            if line.startswith("data:"):
                                return json.loads(line[len("data:"):].strip())
                        return None

                    await post({
                        "jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {
                            "protocolVersion": "2024-11-05",
                            "capabilities": {},
                            "clientInfo": {"name": "drafts-mcp-check", "version": "1"},
                        },
                    })
                    init = await next_event()
                    if not init or "result" not in init:
                        return (0, 0, 0)

                    await post({"jsonrpc": "2.0", "method": "notifications/initialized"})

                    await post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
                    listed = await next_event()
                    if not listed or "result" not in listed:
                        return (0, 0, 0)
                    ssh_ok = 1

                    await post({
                        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                        "params": {"name": PROBE_TOOL, "arguments": PROBE_ARGS},
                    })
                    call_resp = await next_event()
                    if (call_resp and "result" in call_resp
                            and not _is_tcc_failure(call_resp["result"])):
                        tcc_ok = 1
                    # else: ssh_ok=1 ∧ tcc_ok=0 == lost grant (johnw logout).
        except asyncio.TimeoutError:
            return (ssh_ok, tcc_ok, 0)
        except Exception:
            return (ssh_ok, tcc_ok, 0)

        e2e = 1 if (ssh_ok and tcc_ok) else 0
        return (ssh_ok, tcc_ok, e2e)


    METRIC_HELP = {
        "drafts_mcp_bridge_up": "1 if drafts-mcp.service is active",
        "drafts_mcp_sse_open_ok": "1 if drafts-mcp /sse accepted a connection and emitted the endpoint event",
        "drafts_mcp_ssh_hera_ok": "1 if the ssh child + hera drafts-mcp-server answered MCP (init + tools/list)",
        "drafts_mcp_tcc_automation_ok": "1 if a read-only Drafts tools/call returned a non-error result; ssh_ok=1 and this=0 means a lost Automation grant",
        "drafts_mcp_e2e_ok": "1 if the full chain (sse + ssh + Drafts grant) round-tripped a read-only tool within budget",
        "drafts_mcp_check_last_run_timestamp_seconds": "When the drafts-mcp check last ran",
    }


    def write_metrics(metrics: dict) -> None:
        OUT_FINAL.parent.mkdir(parents=True, exist_ok=True)
        lines = []
        for name, value in sorted(metrics.items()):
            lines.append(f"# HELP {name} {METRIC_HELP.get(name, '')}")
            lines.append(f"# TYPE {name} gauge")
            lines.append(f"{name} {value}")
        OUT_TMP.write_text("\n".join(lines) + "\n")
        os.replace(OUT_TMP, OUT_FINAL)


    async def main_async() -> int:
        bridge_up = unit_is_active(DRAFTS_MCP_UNIT)
        sse_ok = await probe_sse_open()
        if sse_ok:
            ssh_ok, tcc_ok, e2e_ok = await probe_e2e()
        else:
            ssh_ok, tcc_ok, e2e_ok = 0, 0, 0
        write_metrics({
            "drafts_mcp_bridge_up": bridge_up,
            "drafts_mcp_sse_open_ok": sse_ok,
            "drafts_mcp_ssh_hera_ok": ssh_ok,
            "drafts_mcp_tcc_automation_ok": tcc_ok,
            "drafts_mcp_e2e_ok": e2e_ok,
            "drafts_mcp_check_last_run_timestamp_seconds": round(time.time(), 3),
        })
        return 0


    if __name__ == "__main__":
        raise SystemExit(asyncio.run(main_async()))
  '';
in
{
  options.services.draftsMcpCheck = {
    enable = lib.mkEnableOption "Drafts MCP bridge end-to-end health probe";
    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Polling interval in seconds.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.drafts-mcp-check = {
      description = "Drafts MCP bridge end-to-end health probe (SSE, ssh→hera, Drafts AppleEvents grant)";
      after = [
        "drafts-mcp.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        # No secret reads — the bridge owns the ssh key; this probe only
        # speaks MCP over loopback SSE. Confined DynamicUser writing to the
        # 1777 textfile dir is the smallest footprint.
        DynamicUser = true;
        ExecStart = "${healthScript}";
        RuntimeMaxSec = "120s";
        ReadWritePaths = [ textfileDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
      };
    };

    systemd.timers.drafts-mcp-check = {
      description = "Timer for drafts-mcp-check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        Unit = "drafts-mcp-check.service";
        AccuracySec = "15s";
      };
    };
  };
}
```

> `RestrictNamespaces = true` added (review low) for parity with hermes/stock-trader hardening. `systemctl is-active` is a read-only query allowed under `@system-service` (matches the hermes check).

### 9.2 EDIT — `/Users/johnw/src/nixos/modules/monitoring/services/default.nix` (import)

Anchor: imports end at `hermes-health-check.nix` (`:50`).

**Before (`:48-51`):**
```nix
    ./openclaw-canary.nix
    ./openclaw-mcporter-check.nix
    ./hermes-health-check.nix

```

**After:**
```nix
    ./openclaw-canary.nix
    ./openclaw-mcporter-check.nix
    ./hermes-health-check.nix
    ./drafts-mcp-check.nix

```

(The enable flag `services.draftsMcpCheck.enable = true;` is in §5 EDIT 2.)

### 9.3 NEW FILE — `/Users/johnw/src/nixos/modules/monitoring/alerts/drafts.yaml`

Auto-discovered by `alerting.nix`. `service: drafts-mcp` is the load-bearing routing label (M2); `self_heal_eligible: "true"` kept per convention.

```yaml
groups:
  - name: drafts_mcp_availability
    interval: 60s
    rules:
      - alert: DraftsMcpBridgeDown
        expr: drafts_mcp_sse_open_ok == 0
        for: 5m
        labels:
          severity: critical
          category: availability
          service: drafts-mcp
          self_heal_eligible: "true"
        annotations:
          summary: "drafts-mcp /sse not accepting connections for 5 minutes"
          description: |
            The host's drafts-mcp.service is not accepting new SSE connections
            on 127.0.0.1:9082. The systemd unit may be up but its single shared
            ssh child to hera has wedged (a dead backend is a silent green
            zombie — design D9). Restarting drafts-mcp.service re-execs the ssh
            child and typically resolves this in seconds; the
            drafts-mcp-self-heal receiver does exactly this.

      - alert: DraftsMcpAskFailing
        expr: drafts_mcp_e2e_ok == 0
        for: 5m
        labels:
          severity: critical
          category: availability
          service: drafts-mcp
          self_heal_eligible: "true"
        annotations:
          summary: "Drafts MCP end-to-end probe failing for 5 minutes"
          description: |
            The 5-minute drafts-mcp check has failed to round-trip a read-only
            Drafts tool (drafts_list_workspaces) through drafts-mcp.service ⇒
            ssh johnw@hera.lan ⇒ drafts-mcp-server ⇒ Drafts.app for 5 minutes.
            Localize via the component metrics: drafts_mcp_sse_open_ok (bridge
            door), drafts_mcp_ssh_hera_ok (transport leg), and
            drafts_mcp_tcc_automation_ok (Drafts AppleEvents grant). The
            drafts-mcp-self-heal receiver restarts drafts-mcp.service on this
            alert (recovers the mcp-proxy single-ssh-child zombie).

      - alert: DraftsMcpTccAutomationLost
        expr: drafts_mcp_ssh_hera_ok == 1 and drafts_mcp_tcc_automation_ok == 0
        for: 5m
        labels:
          severity: critical
          category: integration
          service: drafts-mcp
        annotations:
          summary: "Drafts Automation (TCC) grant lost on hera — ssh OK but Drafts denies"
          description: |
            ssh to hera and drafts-mcp-server are answering MCP
            (drafts_mcp_ssh_hera_ok=1), but every read-only Drafts tools/call
            returns an error (drafts_mcp_tcc_automation_ok=0). This is the
            signature of a lost macOS Automation (kTCCServiceAppleEvents)
            grant — almost always johnw logging OUT of hera's GUI (Aqua)
            session (screen-lock preserves it; logout tears it down — design
            §6.3). Restarting drafts-mcp will NOT help. Remedy on hera: log
            johnw back in to the console GUI session; approve a fresh
            Automation prompt if one appears. Then drafts_mcp_tcc_automation_ok
            returns to 1. (NOT self_heal_eligible: this alert carries
            service=drafts-mcp so it reaches the daemon, but the daemon's
            HEALABLE allowlist excludes it — it no-ops and pages a human.)

      - alert: DraftsMcpCheckStale
        expr: |
          (time() - drafts_mcp_check_last_run_timestamp_seconds > 1200)
          or absent(drafts_mcp_check_last_run_timestamp_seconds)
        for: 10m
        labels:
          severity: warning
          category: monitoring
          service: drafts-mcp
        annotations:
          summary: "Drafts MCP health check has not run in >20 minutes (or never)"
          description: |
            The drafts-mcp-check.timer has not produced fresh metrics in 20
            minutes (or the metric is absent entirely — never run since the
            textfile collector started). Check
            `systemctl status drafts-mcp-check.timer` and the most recent
            `journalctl -u drafts-mcp-check` invocation.
```

### 9.4 NEW FILE — `/Users/johnw/src/nixos/scripts/drafts-mcp-self-heal/actions/restart_drafts_mcp`

`chmod 0755` in git (action scripts ship executable). Modeled on `scripts/hermes-self-heal/actions/restart_mcp` (shebang `#!/run/current-system/sw/bin/bash` verified).

```bash
#!/run/current-system/sw/bin/bash
# drafts-mcp-self-heal action: restart drafts-mcp.service.
#
# Pure, idempotent transport restart — re-execs mcp-proxy's single shared ssh
# child to hera, recovering the silent-green-zombie failure mode where the
# backend died but the proxy keeps returning tool errors forever (design D9).
# Orthogonal to drafts_run_action: this touches ONLY the systemd unit, never a
# Drafts tool call — so the "no autonomous remediator on hera" guarantee holds.
#
# Output: one line of JSON to stdout describing the result.
set -euo pipefail
start_ts=$(date +%s)
rc=0
/run/current-system/sw/bin/systemctl restart drafts-mcp.service || rc=$?
end_ts=$(date +%s)
duration=$((end_ts - start_ts))
if [ "$rc" -eq 0 ]; then
  printf '{"ok": true, "duration_s": %d, "notes": "drafts-mcp restarted"}\n' "$duration"
else
  printf '{"ok": false, "duration_s": %d, "notes": "systemctl restart returned %d"}\n' "$duration" "$rc"
fi
```

### 9.5 NEW FILE — `/Users/johnw/src/nixos/modules/services/drafts-mcp-self-heal.nix`

Minimal single-action webhook receiver (M1). **Port `9085`** (the 9097→9085 fix). `send_resolved`/sudoers patterns from `hermes-self-heal.nix`.

```nix
# Drafts MCP self-heal — a one-action Alertmanager webhook receiver.
#
# DraftsMcpBridgeDown / DraftsMcpAskFailing (service=drafts-mcp,
# self_heal_eligible=true) → POST /alert here → `systemctl restart
# drafts-mcp.service`. That restart re-execs mcp-proxy's single shared ssh
# child to hera (the design-D9 zombie fix). It is the ONLY automated
# remediation, it is pure systemctl, and it is orthogonal to drafts_run_action.
#
# Deliberately NOT reusing hermes-self-heal: that daemon is hermes-keyed
# (ACTION_MAP on hermes alert names, reads hermes_health.prom, ignores unknown
# alerts) and routing a DraftsMcp* alert at it would no-op without
# cross-contaminating an unrelated critical service.
#
# DraftsMcpTccAutomationLost is intentionally NOT in HEALABLE (a lost hera GUI
# session — restarting drafts-mcp cannot fix it; it pages a human).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.draftsMcpSelfHeal;
  user = "drafts-mcp-heal";
  actionsDir = "/etc/nixos/scripts/drafts-mcp-self-heal/actions";

  daemonScript = pkgs.writeText "drafts-mcp-self-heal.py" ''
    #!${pkgs.python3}/bin/python3
    """Single-action Alertmanager webhook -> systemctl restart drafts-mcp.

    Listens on 127.0.0.1:${toString cfg.port}/alert. For each FIRING alert
    whose name is in HEALABLE, runs the (sudo-allowlisted) restart action,
    debounced. No AI tier, no incident store, no escalation ladder.
    """
    from __future__ import annotations

    import json
    import subprocess
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    PORT = ${toString cfg.port}
    ACTION = "${actionsDir}/restart_drafts_mcp"
    HEALABLE = {"DraftsMcpBridgeDown", "DraftsMcpAskFailing"}
    MIN_RESTART_INTERVAL_S = 300.0
    _last_restart = [0.0]


    def run_action() -> None:
        now = time.monotonic()
        if now - _last_restart[0] < MIN_RESTART_INTERVAL_S:
            return
        _last_restart[0] = now
        try:
            subprocess.run(
                ["sudo", "-n", ACTION],
                capture_output=True, text=True, timeout=120,
            )
        except Exception:
            pass


    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw or b"{}")
            except Exception:
                payload = {}
            for alert in payload.get("alerts", []):
                if alert.get("status") != "firing":
                    continue
                name = alert.get("labels", {}).get("alertname")
                if name in HEALABLE:
                    run_action()
                    break
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")


    if __name__ == "__main__":
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in
{
  options.services.draftsMcpSelfHeal = {
    enable = lib.mkEnableOption "drafts-mcp self-heal webhook receiver";
    port = lib.mkOption {
      type = lib.types.port;
      default = 9085;
      description = "Loopback port for the Alertmanager webhook (9085 — verified free vs 9097 MailArchiver collision; re-verify vs ss -ltnp).";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      description = "Drafts MCP self-heal daemon";
    };
    users.groups.${user} = { };

    security.sudo.extraConfig = ''
      Defaults:${user} !mail_no_perms,!mail_no_user,!mail_badpass,!mail_always
    '';

    security.sudo.extraRules = [
      {
        users = [ user ];
        commands = [
          {
            command = "${actionsDir}/restart_drafts_mcp";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    systemd.services.drafts-mcp-self-heal = {
      description = "Drafts MCP self-heal webhook receiver (restart drafts-mcp.service)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "alertmanager.service"
      ];
      wants = [ "network-online.target" ];
      path = [
        "/run/wrappers"
        pkgs.coreutils
        pkgs.systemd
      ];
      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        Restart = "always";
        RestartSec = "5s";
        ExecStart = "${pkgs.python3}/bin/python3 ${daemonScript}";
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = false; # needs the setuid sudo wrapper
        PrivateTmp = true;
        RestrictSUIDSGID = false; # sudo wrapper is setuid
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # python compiles bytecode
        CapabilityBoundingSet = [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_DAC_OVERRIDE"
        ];
        ReadWritePaths = [ "/run/sudo" ];
      };
    };

    networking.firewall.allowedTCPPorts = [ ]; # 127.0.0.1 only
  };
}
```

### 9.6 EDIT — `/Users/johnw/src/nixos/modules/services/alertmanager.nix` (route + receiver)

**Route** — insert after the hermes self-heal route (closing `}` at `:91`, before the storage-alerts comment at `:92`). The comment documents the M2 carve-out and the watchdog-loop trap (security-review low).

**Insert after `:91`:**
```nix
          # Drafts MCP self-heal pipeline — service=drafts-mcp alerts go to
          # the drafts-mcp-self-heal webhook receiver. continue=true keeps the
          # email/critical/iPhone paths firing so a human still sees it.
          # NOTE: DraftsMcpTccAutomationLost also carries service=drafts-mcp and
          # so reaches the daemon, but the daemon's HEALABLE allowlist excludes
          # it (a lost hera GUI grant is not restart-fixable) — delivered but
          # no-ops, then continues to email/iPhone for a human.
          # NOTE: any future drafts-self-heal watchdog alert MUST carry a
          # distinct service label (e.g. service=drafts-mcp-self-heal) so it
          # never loops back to the possibly-dead daemon, mirroring the openclaw
          # / hermes self-watchdog exclusions above.
          {
            match = {
              service = "drafts-mcp";
            };
            receiver = "drafts-mcp-self-heal";
            group_wait = "10s";
            group_interval = "5m";
            repeat_interval = "4h";
            continue = true;
          }
```

**Receiver** — insert after the `hermes-self-heal` receiver (closing `}` at `:245`, before the iPhone-notifier comment at `:246`). **`send_resolved = true`** to match the two existing self-heal receivers verbatim (`:233`, `:242`). **`url` port = 9085** = `services.draftsMcpSelfHeal.port`.

**Insert after the `hermes-self-heal` receiver block (`:245`):**
```nix
        {
          name = "drafts-mcp-self-heal";
          webhook_configs = [
            {
              url = "http://127.0.0.1:9085/alert";
              send_resolved = true;
            }
          ];
        }
```

(The enable flag `services.draftsMcpSelfHeal.enable = true;` and the import are in §5 EDIT 1/EDIT 2.)

### 9.7 EDIT — `/Users/johnw/src/nixos/docs/ports.txt` (self-heal webhook line)

Add a loopback line in the 909x self-heal band (after `:141` `9092 … OpenClaw Self-Heal` / near `:145` `9098 … Hermes Self-Heal`):

```
9085 127.0.0.1 Drafts MCP Self-Heal webhook receiver
```

### 9.8 OPTIONAL — `/Users/johnw/src/nixos/modules/monitoring/services/openclaw-mcporter-check.nix`

Defer until the OpenClaw `drafts-hera` registration (§8 EDIT 1) lands, else the check reports `drafts-hera` missing (=0). Anchor: `EXPECTED_SERVERS` at `:40-48`.

**Before:**
```python
    EXPECTED_SERVERS = (
        "home-assistant",
        "stock-trader",
        "email-contacts",
        "google-calendar-personal",
        "google-calendar-work",
        "searxng",
        "vane",
    )
```

**After:**
```python
    EXPECTED_SERVERS = (
        "home-assistant",
        "stock-trader",
        "email-contacts",
        "google-calendar-personal",
        "google-calendar-work",
        "searxng",
        "vane",
        "drafts-hera",
    )
```

The structural validator already accepts a `url`-based entry (`:65,69`), so `drafts-hera = {url:...}` passes with no logic change.

---

## 10. Section F — Cross-repo (hera authorized_keys, secrets, promptdeploy)

### 10.1 EDIT — `/Users/johnw/src/nix/config/darwin.nix` (forced-command pubkey)

Anchor: `keys = [` at `:34`; existing card keys `:36-37`; closing `];` at `:38`. Insert a new element after `:37` (escaped-double-quote form to match the existing `"…"` entries).

**Before (`config/darwin.nix:33-38`):**
```nix
        openssh.authorizedKeys = {
          keys = [
            # GnuPG auth key stored on Yubikeys
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAj2IzkXyXEl+ReCg9H+t55oa6GIiumPWeufcYCWy3F cardno:31_768_527"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAING2r8bns7h9vZIfZSGsX+YmTSe2Tv1X8f/Qlqo+RGBb cardno:14_476_831"
          ];
```

**After:**
```nix
        openssh.authorizedKeys = {
          keys = [
            # GnuPG auth key stored on Yubikeys
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAj2IzkXyXEl+ReCg9H+t55oa6GIiumPWeufcYCWy3F cardno:31_768_527"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAING2r8bns7h9vZIfZSGsX+YmTSe2Tv1X8f/Qlqo+RGBb cardno:14_476_831"

            # drafts-mcp bridge (vulcan drafts-mcp.service) — pinned to exec
            # drafts-mcp-server ONLY; SSH_ORIGINAL_COMMAND is ignored by the
            # forced command. `restrict` disables pty/forwarding/X11/agent.
            # This is the per-key least-privilege gate (NOT key-files.nix,
            # which grants an unrestricted login shell). Replace AAAA...PLACEHOLDER
            # with the real ed25519 pubkey from the §10.2 keygen.
            "command=\"/etc/profiles/per-user/johnw/bin/drafts-mcp-server\",restrict,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA...PLACEHOLDER drafts-bridge@vulcan"
          ];
```

> `restrict` already implies the four `no-*` flags; they are kept as redundant self-documentation. Apply on hera via the normal darwin switch.

### 10.2 SECRETS — `/etc/nixos/secrets/secrets.yaml` (note the `/secrets/` subdir)

**Design correction (BOTH reviewers, load-bearing):** the canonical sopsfile is **`/etc/nixos/secrets/secrets.yaml`** (subdir), confirmed by `flake.nix:25`, `modules/core/system.nix:74`, `hosts/vulcan/default.nix:287` — NOT the bare `/etc/nixos/secrets.yaml`. Editing the bare path would target the wrong/nonexistent file and activation would fail.

**Keygen (run on vulcan):**
```sh
ssh-keygen -t ed25519 -N "" -C "drafts-bridge@vulcan" -f /tmp/drafts-bridge-ed25519
cat /tmp/drafts-bridge-ed25519.pub   # -> paste into config/darwin.nix §10.1
# After sealing the private half below: shred -u /tmp/drafts-bridge-ed25519*
```

**Add the private key** (auto-covered by the `.*\.yaml$` rule — no `.sops.yaml` edit):
```sh
sops /etc/nixos/secrets/secrets.yaml
```
```yaml
drafts:
  hera-ssh-private-key: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    <PRIVATE KEY MATERIAL — NEVER SHOWN HERE>
    -----END OPENSSH PRIVATE KEY-----
```
```sh
git -C /etc/nixos/secrets add secrets.yaml
git -C /etc/nixos/secrets commit -m "Add drafts/hera-ssh-private-key for drafts-mcp bridge"
git -C /etc/nixos/secrets push
```

The module consumes it via `sops.secrets."drafts/hera-ssh-private-key"` (§5) → `LoadCredential` → `/run/credentials/drafts-mcp.service/hera-ssh-key` (DynamicUser-safe; systemd reads it as root before the user switch; the wrapper hardcodes the path because the MCP SDK strips `$CREDENTIALS_DIRECTORY` — see §"Review fixes applied").

### 10.3 CREATE — `/Users/johnw/src/promptdeploy/mcp/drafts-hera.yaml`

`name: drafts-hera` (≠ `drafts`, passes the dedup gate); `only: [claude-vulcan]` (host operator, full toolset). ssh args add `-T`, the dedicated `-i` key + `IdentitiesOnly=yes`, and `ConnectTimeout`/`ServerAlive*`.

> **Correction (2026-06-09, verified):** `IdentitiesOnly=yes` is **OMITTED** for this operator path (an earlier draft included it). vulcan's `~/.ssh/config` pins `IdentityFile id_vulcan` under `Host *`, and hera does **not** authorize `id_vulcan`; with `IdentitiesOnly=yes` ssh offers only that key and fails `Permission denied`. Without it, ssh uses johnw's agent/default key (authorized on hera) and succeeds — confirmed end-to-end (vulcan→hera→`drafts-mcp-server`→`drafts_get_drafts`, no `-1743`). `IdentitiesOnly=yes` + a dedicated `-i` key belongs to the **bridge service** (§5) only, never this operator path.

> **Correction superseded (2026-06-10, deployed):** the above assumed the operator path could lean on johnw's agent/YubiKey — but **vulcan has no YubiKey and never will**, so the agent route cannot run unattended. The final operator entry authenticates with the **dedicated forced-command key** (the same key the bridge service uses), read directly by johnw from the sops-decrypted `/run/secrets/drafts/hera-ssh-private-key` (owner johnw, mode 0400 — dual-use by design, §5). With an explicit `-i`, `IdentitiesOnly=yes` is back **on** (it pins ssh to exactly that key, avoiding the `id_vulcan` trap that motivated the first correction). Verified end-to-end 2026-06-10: this exact invocation returned the full 20-tool `tools/list` from Drafts. Because the key is forced-command-pinned on hera, the remote-command arg is ignored and the connection can only ever run `drafts-mcp-server`.

```yaml
name: drafts-hera
description: Drafts.app on hera (macOS) via SSH-stdio to drafts-mcp-server — host Claude Code (claude-vulcan, operator context, FULL toolset incl. drafts_run_action). Bypasses the SSE bridge; the autonomous OpenClaw/Hermes microVMs use the write-gated SSE endpoint instead.
command: ssh
args:
  - "-T"
  - "-i"
  - "/run/secrets/drafts/hera-ssh-private-key"
  - "-o"
  - "IdentitiesOnly=yes"
  - "-o"
  - "BatchMode=yes"
  - "-o"
  - "StrictHostKeyChecking=yes"
  - "-o"
  - "ConnectTimeout=10"
  - "-o"
  - "ServerAliveInterval=30"
  - "-o"
  - "ServerAliveCountMax=3"
  - "johnw@hera.lan"
  - "/etc/profiles/per-user/johnw/bin/drafts-mcp-server"
scope: user
enabled: true
only:
  - claude-vulcan
```

> **Privilege-boundary note (security-review, updated 2026-06-10):** both the operator path and the `DynamicUser` bridge service authenticate with the **same dedicated forced-command key**, so neither can be repurposed into an arbitrary hera shell — the `restrict,no-pty,...` forced command pins every connection to `drafts-mcp-server` (full toolset; the explicit remote-command arg above is ignored and kept only as documentation). The operator/agent split is enforced one layer up instead: the operator path gets the full toolset, while the VM-facing SSE endpoint passes through `drafts-tool-filter`, which strips the 9 write tools. The original plan to let the operator ride johnw's unrestricted YubiKey identity was dropped — vulcan has no YubiKey, and the forced-command pin is strictly stronger anyway.

### 10.4 EDIT — `/Users/johnw/src/promptdeploy/mcp/drafts.yaml` (comment only)

Anchor: the NEVER list at `:17-18`. `name: drafts` and `only: [claude-personal]` (`:23-24`) unchanged.

**Before (`mcp/drafts.yaml:17-18`):**
```yaml
#   NEVER add (Linux — no Drafts.app, no osascript): claude-vulcan, claude-vps,
#     claude-positron, claude-andoria, claude-git-ai-remote, opencode-vulcan.
```

**After:**
```yaml
#   NEVER add (Linux — no Drafts.app, no osascript): claude-vps,
#     claude-positron, claude-andoria, claude-git-ai-remote, opencode-vulcan.
#   NOTE: claude-vulcan now reaches Drafts via mcp/drafts-hera.yaml
#     (SSH-stdio to johnw@hera.lan running drafts-mcp-server over the LAN —
#     a remote Mac, not a local osascript binary). The prohibition above is
#     specifically against a *local* drafts-mcp-server on Linux, which still
#     holds: this `drafts` entry (command = the local bin) must never target a
#     Linux profile. drafts-hera.yaml is the correct vehicle for vulcan.
```

### 10.5 OPTIONAL — `/Users/johnw/src/nix/config/launchd.nix` (keep Drafts resident)

Cold-Drafts mitigation (Q4), orthogonal to the rejected TCC fallback. Add inside the `// lib.optionalAttrs (hostname == "hera") { … }` user-agents block (opens at `:212`; `home = "/Users/johnw"` defined at `:9`). Ship only if cold-launch latency is observed.

```nix
      # Keep Drafts.app resident in johnw's Aqua (GUI) session so the vulcan
      # drafts-mcp bridge never pays a cold-launch first-call deadline.
      # `open -gj` launches hidden in the background without stealing focus.
      # KeepAlive.SuccessfulExit=false relaunches on crash only, so a
      # deliberate Cmd-Q sticks (politeness; like omlx at :205).
      keep-drafts-resident = {
        script = ''
          /usr/bin/open -gja /Applications/Drafts.app
        '';
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
          ProcessType = "Interactive";
          StandardOutPath = "${home}/Library/Logs/keep-drafts-resident.log";
          StandardErrorPath = "${home}/Library/Logs/keep-drafts-resident.log";
        };
      };
```

> Review low: `ThrottleInterval`/`LimitLoadToSessionType` are standard launchd.plist keys but unexercised in this file. Dropped from the minimal form above; if added, confirm `darwin-rebuild build .#hera` accepts them, else stay with the `RunAtLoad`/`KeepAlive.SuccessfulExit`/`ProcessType` set used by `omlx`.

---

## 11. Verification gates

Run per-phase (build/switch/commit are **user-gated**; commits need the YubiKey pinentry).

| # | Gate | Command / check |
|---|---|---|
| 1 | Eval clean | `nix flake check` (exercises the new module/package, the Hermes `tools` submodule, alert auto-discovery, the alertmanager route/receiver). |
| 2 | Build clean | `nixos-rebuild build --flake '/Users/johnw/src/nixos#vulcan'` (fails until `pinnedKnownHosts` real key + the sops secret exist — fail-closed by design). |
| 3 | Format | `nix fmt` clean on all new/edited Nix files. |
| 4 | Alerts parse | `promtool check rules modules/monitoring/alerts/drafts.yaml` (validates the `or absent(...)` expr). |
| 5 | promptdeploy | `promptdeploy validate` exits 0 (the D6 `drafts-hera` name is what makes the two-file coexistence legal). |
| 6 | Port liveness | On vulcan: `ss -ltnp \| grep -E ':9082\|:9085'` returns nothing pre-switch; `nft list ruleset \| grep 9082` shows no pre-existing rule. |
| 7 | SSE bind | Post-switch: `ss -ltnp \| grep 9082` shows `127.0.0.1:9082` only (LAN cannot reach it); `curl -sN http://127.0.0.1:9082/sse` opens a stream. |
| 8 | DNAT landed | `iptables -t nat -S PREROUTING \| grep 9082` shows the rule on BOTH `br-openclaw` and `hermes-br0`; `nft list ruleset` shows 9082 in both guests' OUTPUT DNAT sets after the VMs restart. |
| 9 | From-VM probe | From inside each VM, the agent lists `drafts-hera`; a read tool round-trips via DNAT. |
| 10 | **run_action absent** | OpenClaw: `tools/list` from the VM endpoint **excludes** all 9 write tools; a direct `tools/call drafts_run_action` returns `isError:true` (shim deny). Hermes: `tools/call drafts_run_action` is refused **client-side** (not merely absent from `tools/list`) — proves `tools.include` default-deny. |
| 11 | e2e drafts_search | `drafts_search` (or `drafts_list_workspaces`) returns hera content through every leg; `cat /var/lib/prometheus-node-exporter-textfiles/drafts_mcp.prom` shows all 6 metrics with `drafts_mcp_tcc_automation_ok 1`. |
| 12 | self-heal loop | Stop hera's `drafts-mcp-server` → `DraftsMcpAskFailing` fires within ~10m → Alertmanager delivers to `127.0.0.1:9085/alert` → `drafts-mcp.service` restarts → `drafts_mcp_e2e_ok` returns to 1. `journalctl -u drafts-mcp-self-heal` confirms delivery + 300s debounce. |
| 13 | TCC-lost sim | Log johnw OUT of hera's GUI briefly → `drafts_mcp_ssh_hera_ok 1 ∧ drafts_mcp_tcc_automation_ok 0` → `DraftsMcpTccAutomationLost` fires (category=integration) and is **NOT** healed; log back in → returns to 1. |
| 14 | No secrets | No key material in any committed file or in output. |

---

## 12. Security posture

- **Write-tool denial is layered.** OpenClaw: the `drafts-tool-filter` shim is the SOLE enforcement point — strips the 9 write tools from `tools/list` AND rejects them on `tools/call`, and **fails closed** on unparseable client→child lines. Hermes: a `tools.include` allowlist (default-deny). Both VMs therefore never see `drafts_run_action`. Host CC (operator) gets the full toolset deliberately.
- **Least privilege on hera** is enforced at the **key** layer (`authorized_keys` forced-command pins `drafts-mcp-server`, ignores `SSH_ORIGINAL_COMMAND`), not a Unix identity (TCC requires johnw's Aqua session).
- **Loopback-only bind** (`127.0.0.1:9082`); VMs reach it only via the two-stage DNAT chain — no LAN exposure, no new nginx/TLS/CA surface.
- **Bridge service** is a hardened `DynamicUser` (stateless), reads the ssh key only via `LoadCredential` (root-owned `0400`, materialized read-only into the unit namespace).
- **Pinned `known_hosts`** (fail closed on host-key change). The probe's `ssh_ok=1 ∧ tcc_ok=0` split distinguishes a lost TCC grant from a transport break.
- **Self-heal is pure `systemctl restart`** — never a Drafts tool call, orthogonal to `run_action`. Sudoers grants only the absolute path to the one action script.
- **No secret material** in any committed file; the private key lives only in sops + the per-unit credential dir at runtime.

## 13. Rollback (pure-additive, per-repo)

- **vulcan:** `git revert` the module/DNAT/registration/monitoring commits + `nixos-rebuild switch` + `systemctl restart microvm@openclaw microvm@hermes`. Removing 9082 from each `dnatPorts` closes the egress. Removing the enable flags stops `drafts-mcp.service`, `drafts-mcp-check`, and `drafts-mcp-self-heal`.
- **hera:** revert the `config/darwin.nix` `authorized_keys` line + darwin switch (instantly de-authorizes the key). Revert the optional launchd agent if shipped.
- **promptdeploy:** remove/revert `mcp/drafts-hera.yaml` + revert the `drafts.yaml` comment + redeploy.
- **Secret:** leaving `drafts/hera-ssh-private-key` in `secrets.yaml` is inert once the pubkey is removed; rotate if exposure is suspected.

## 14. Key-rotation runbook (ordering is load-bearing)

The sops change carries `restartUnits = ["drafts-mcp.service"]`, so applying a new private key restarts the bridge onto it immediately — the matching pubkey MUST already be authorized on hera, or the bridge auth-fails and crash-loops. **Add-new → cut-over → remove-old:**

1. **hera FIRST (additive).** Generate the new keypair (§10.2). Add the **new** pubkey to `config/darwin.nix` as a *second* forced-command literal **alongside** the old. Darwin switch. → hera accepts both; bridge undisturbed on the old key.
2. **vulcan SECOND (cut-over).** `sops /etc/nixos/secrets/secrets.yaml`, replace `drafts/hera-ssh-private-key` with the **new** private key. Commit/push the secrets tree. `nixos-rebuild switch --flake .#vulcan`. `restartUnits` reconnects on the new key (now authorized). Verify `drafts_mcp_ssh_hera_ok=1 ∧ drafts_mcp_tcc_automation_ok=1`.
3. **hera THIRD (remove old).** Once healthy on the new key, delete the **old** pubkey literal from `config/darwin.nix`. Darwin switch. → rotation complete.

Reversed order leaves the running service holding a key hera no longer trusts the instant the unit restarts → auth-fail crash-loop.

**Host-key (known_hosts) rotation** (separate concern — the *pinned `known_hosts`* store file, not the client key): if hera is reinstalled / its host key changes, the pinned `UserKnownHostsFile` no longer matches → `StrictHostKeyChecking=yes` aborts every connection → bridge crash-loops. Recovery: (1) on vulcan, re-capture `ssh-keyscan -t ed25519 hera.lan`; (2) update the `pkgs.writeText` body in `drafts-mcp.nix`; (3) `nixos-rebuild switch` (restarts the unit onto the new pin). Until that switch the bridge is down by design; `ssh_ok=0` flags it distinctly from a TCC loss (`ssh_ok=1 ∧ tcc_ok=0`).

## 15. Residual / operational notes

- **TCC longevity (non-blocking).** Phase-1 validated session-bound + origin-agnostic grant survival across fresh connections and the node-wrapped responsible-process chain. **Unverified:** >1 h longevity and behaviour across johnw **logout** (logout tears down the Aqua session → grant lost). This is precisely what `DraftsMcpTccAutomationLost` (category=integration, NOT self-healed) detects and pages a human for. During Phase 1, capture one real `-1743` `tools/call` envelope over the bridge and confirm `_is_tcc_failure()` matches (tighten the matcher if the envelope differs from `isError`/`-1743`/`not authorized`).
- **Cold Drafts.** If `drafts-mcp-server` does not auto-launch Drafts (or an auto-launched instance does not inherit the grant), ship the optional §10.5 launchd `KeepAlive` agent and add a bounded first-call deadline (the probe's `E2E_BUDGET_S=45` and ssh `ConnectTimeout=10`/`ServerAlive*` already bound host-side hangs).
- **Concurrency.** A single shared ssh child serializes ALL calls at Drafts (OpenClaw + Hermes + host CC head-of-line block). Accepted per the locked decisions; the ssh `ServerAlive*` + probe `RuntimeMaxSec` provide the host-side deadline (mcporter has no per-server timeout knob).
- **Sequencing trap.** Register the VMs (§8) and enable monitoring AFTER the bridge + DNAT exist, else the VMs/probe target a dead `127.0.0.1:9082`. Land the real hera host key + the sops secret in the SAME commit as `services.drafts-mcp.enable = true` (the §5 assertion fails closed otherwise).
- **`MemoryMax=256M`** on the bridge is a starting estimate (mcp-proxy + shim + one ssh child is lightweight; hermes-mcp uses 512M). Confirm under load; raise if it OOMs on large `drafts_search` payloads.
- **`openclaw-mcporter-check.nix` EXPECTED_SERVERS** (§9.8) is optional and deferred until the OpenClaw registration lands.
- **Anchor drift corrected vs design.** The drafts-mcp import goes after `hermes-mcp.nix:152` (the import block continues with `hermes-self-heal.nix:153`, not ending at 152). Hermes `dnatPorts` tail is `5232`/`5432`/`8123` (`:68-70`), not `5432`/`8123`. The alertmanager self-heal receivers use `send_resolved = true` (`:233`,`:242`), not `false`. The hermes `mcpServers` block has 7 entries (a `perplexity` entry at `:734` sits between `email-contacts` and `org-db`); the insert-after-`org-db` anchor (`:749`) is unaffected.
