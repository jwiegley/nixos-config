# pkgs/drafts-tool-filter/default.nix
#
# Transparent MCP *stdio* filter shim. Spawns the real MCP child (passed as
# argv, e.g. the drafts ssh wrapper), pumps bytes both ways, and rewrites
# JSON-RPC ONLY where policy requires:
#
#   (a) tools/list RESULTS from the child  -> strip the denied tools
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
# This is the ONLY tool enforcement point for OpenClaw (mcporter has no
# per-server tool filter; mcp-proxy is transparent). Hermes is additionally
# gated by a tools.include allowlist at registration; host operator
# (claude-vulcan) bypasses the bridge and gets the full toolset.
#
# POLICY (owner decision 2026-06-10, superseding the launch read-only
# posture): the agent VMs get the full READ/WRITE draft surface — create,
# update, tag, flag, archive, inbox, trash, open workspace — because the
# point of the bridge is that agents can MAKE drafts on request, not just
# see them. The single remaining denial is drafts_run_action: it executes
# arbitrary Drafts actions (including script actions) as johnw inside
# hera's GUI session — code execution, not draft management — and stays
# operator-only.
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

    # drafts_run_action is code-exec as johnw on hera (arbitrary Drafts
    # actions, including script actions) and stays operator-only. Every
    # other write tool (create/update/tag/flag/archive/inbox/trash/
    # open_workspace) is deliberately ALLOWED for the agent VMs — owner
    # decision 2026-06-10; see the header comment.
    DENY = frozenset({
        "drafts_run_action",
    })

    POLICY_MSG = (
        "Tool denied by the drafts-mcp bridge policy: drafts_run_action "
        "(arbitrary Drafts action execution on hera) is not available to "
        "autonomous agents on this endpoint. All other draft read/write "
        "tools are available."
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
