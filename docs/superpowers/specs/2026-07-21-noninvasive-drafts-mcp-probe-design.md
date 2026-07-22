# Non-invasive Drafts MCP Health Probe Design

## Context

Vulcan currently runs `drafts-mcp-check.timer` every 300 seconds. The scheduled
probe initializes an MCP session, lists tools, and calls the read-only
`drafts_list_workspaces` tool. That final call executes AppleScript against
Drafts.app on Hera. macOS delivers a reopen AppleEvent to Drafts, which can
make the application visible after the user has hidden it.

The transport and application checks are currently conflated in the
`drafts_mcp_e2e_ok` metric. This makes a periodic GUI side effect part of
monitoring and causes transport self-healing to depend on an interactive
application check.

## Requirements

- No scheduled service or timer may invoke a Drafts MCP tool, address
  Drafts.app through AppleEvents, launch it, reopen it, or reveal it.
- The five-minute timer must continue to verify the Vulcan service, loopback
  SSE endpoint, persistent SSH child, Hera forced command, and MCP server.
- Periodic metrics and alerts must describe only properties the scheduled
  probe actually observes.
- Transport failures must remain eligible for the existing bounded
  `drafts-mcp.service` restart.
- An application/TCC check must remain available only through an explicit,
  untimed operator action, and its name and documentation must warn that it
  contacts Drafts.app.
- The manual check must remain read-only and may call only
  `drafts_list_workspaces`; it must never invoke `drafts_run_action` or
  another mutating tool.
- The probe must keep hard timeouts, atomic Prometheus textfile replacement,
  systemd confinement, and secret-free operation.
- The deployed Vulcan configuration must be verified against Hera event logs,
  not merely by source inspection.

## Considered Approaches

### 1. Transport-only schedule plus an explicit manual app check

The timer stops after MCP `initialize` and `tools/list`. A separate
untimed systemd service adds one read-only `tools/call` only when an operator
starts it explicitly. Metrics and alerts are renamed around transport health.

This retains useful automated coverage without touching the GUI and is the
selected approach.

### 2. Run the app check only when Drafts appears visible

Vulcan would first query a Hera-side visibility signal and conditionally call
the tool. This adds another remote interface, has race conditions between the
visibility check and AppleEvent delivery, and still permits monitoring to
change application focus. It is rejected.

### 3. Disable the probe timer

This completely removes the side effect but also loses early detection and
self-healing of the persistent SSH/proxy failure mode. It is rejected because
the transport can be monitored safely.

## Architecture

### Scheduled transport probe

The scheduled executable has a default mode that performs:

1. `systemctl is-active drafts-mcp.service`.
2. A bounded GET of `http://127.0.0.1:9082/sse`.
3. A fresh bounded SSE MCP session.
4. `initialize`, `notifications/initialized`, and `tools/list`.
5. Atomic publication of transport-only metrics.

Its request construction has a tested invariant: default mode contains no
`tools/call` request. The scheduled service description and module option
must say “transport health probe,” not “end-to-end Drafts app probe.”

The periodic metric set is:

- `drafts_mcp_bridge_up`
- `drafts_mcp_sse_open_ok`
- `drafts_mcp_ssh_hera_ok`
- `drafts_mcp_check_last_run_timestamp_seconds`

`drafts_mcp_ssh_hera_ok` remains valid because a successful `tools/list`
response proves the proxy's SSH child, Hera's forced command, and the MCP
server. The scheduled probe removes `drafts_mcp_tcc_automation_ok` and
`drafts_mcp_e2e_ok`; retaining either would claim evidence the timer no
longer collects.

### Explicit application probe

An untimed `drafts-mcp-app-check.service` runs the same bounded MCP handshake
with an explicit app-check flag and then calls only
`drafts_list_workspaces`. It prints a concise success or failure to the
journal and exits nonzero on transport, tool, or TCC failure. It does not
publish periodic Prometheus metrics, has no `wantedBy`, and has no timer.
Its unit description warns that it contacts Drafts.app on Hera and may reveal
the application.

The operator command is:

```sh
sudo systemctl start drafts-mcp-app-check.service
sudo journalctl -u drafts-mcp-app-check.service -n 20 --no-pager
```

### Alerts and self-healing

`DraftsMcpBridgeDown` continues to cover an unavailable SSE endpoint.
`DraftsMcpAskFailing` is replaced by
`DraftsMcpTransportFailing`, which fires only when SSE is open but
`tools/list` cannot complete. This avoids duplicate alerts when the bridge
itself is down.

`DraftsMcpTccAutomationLost` is removed because periodic monitoring no
longer observes TCC. The self-heal daemon replaces
`DraftsMcpAskFailing` with `DraftsMcpTransportFailing` in its allowlist.
Its only remediation remains restarting `drafts-mcp.service`.

A stale-check alert continues to prove that the transport timer is running.
TCC or Drafts application failures are diagnosed through the explicit manual
service or a real client failure, not inferred as green.

## Implementation Boundary

The Python probe is moved from an opaque Nix indented string into a standalone
source file so request sequencing can be tested directly. The Nix module
packages that source with the required Python/httpx environment and defines
the scheduled and manual units. Focused tests cover the no-`tools/call`
default, the single read-only manual call, transport-only metrics, manual
failure exit status, and alert/self-heal names.

No Drafts MCP package, Hera SSH key, forced-command configuration, tool filter,
or application preference changes are required.

## Verification

Before deployment:

- The focused regression test must first fail against the old behavior.
- Python tests, Nix formatting/evaluation, Prometheus rule validation, and the
  repository's full authoritative check must pass.
- Static inspection of the generated scheduled unit must show no app-check
  argument, while the manual unit has no timer or install target.

On Vulcan:

- Follow the repository's `/etc/nixos/.nixos-build` lock protocol, build,
  and switch the `vulcan` flake output.
- Confirm the timer remains active and invokes only the transport service.
- Run at least one scheduled probe and confirm the four transport metrics are
  fresh and the removed app/TCC metrics are absent from the current textfile.
- Correlate the probe interval with Hera unified logs and confirm no
  `drafts_list_workspaces` tool call, `osascript` child, Drafts reopen
  AppleEvent, or visibility assertion occurs.
- Run the manual service once and confirm its journal explicitly records the
  read-only result; this intentional invocation may address or reveal Drafts.
- Hide Drafts again and observe another scheduled probe cycle to confirm the
  application remains hidden and receives no reopen event.
