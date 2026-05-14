"""SSE MCP server exposing the six hermes-mcp tools."""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from mcp.server.lowlevel import Server
from mcp.server.sse import SseServerTransport
from mcp.types import TextContent, Tool
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.routing import Mount, Route
import uvicorn

from hermes_mcp import tools
from hermes_mcp.config import Config
from hermes_mcp.hermes_client import HermesClient
from hermes_mcp.session_store import SessionStore

logger = logging.getLogger("hermes_mcp")

# Tools that wrap a long upstream call to Hermes Agent and benefit from
# heartbeats. Heartbeats reset the client-side `resetTimeoutOnProgress`
# timer so a 15-20 minute analytical run doesn't trip the MCP client's
# tool-call timeout. The other tools (list/get/delete metadata) are fast
# enough that heartbeats are pointless overhead.
_HEARTBEAT_TOOLS = frozenset(
    {"ask_hermes", "continue_session", "summarize_session"}
)
_HEARTBEAT_INTERVAL_SECONDS = 30.0

_TOOL_SCHEMAS: list[Tool] = [
    Tool(
        name="ask_hermes",
        description=(
            "Send a prompt to Hermes Agent. If session_id is omitted, a "
            "fresh session is created. Returns Hermes' reply."
        ),
        inputSchema={
            "type": "object",
            "required": ["prompt"],
            "properties": {
                "prompt": {"type": "string"},
                "session_id": {"type": "string"},
            },
        },
    ),
    Tool(
        name="start_session",
        description="Create a new named (or anonymous) Hermes conversation session.",
        inputSchema={
            "type": "object",
            "properties": {"name": {"type": "string"}},
        },
    ),
    Tool(
        name="continue_session",
        description="Send a follow-up prompt within an existing session.",
        inputSchema={
            "type": "object",
            "required": ["session_id", "prompt"],
            "properties": {
                "session_id": {"type": "string"},
                "prompt": {"type": "string"},
            },
        },
    ),
    Tool(
        name="list_sessions",
        description="List Hermes sessions, most-recently-used first.",
        inputSchema={
            "type": "object",
            "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 200}},
        },
    ),
    Tool(
        name="summarize_session",
        description="Ask Hermes to summarize a session; stores the summary.",
        inputSchema={
            "type": "object",
            "required": ["session_id"],
            "properties": {"session_id": {"type": "string"}},
        },
    ),
    Tool(
        name="delete_session",
        description="Delete a Hermes session from local bookkeeping.",
        inputSchema={
            "type": "object",
            "required": ["session_id"],
            "properties": {"session_id": {"type": "string"}},
        },
    ),
]

_TOOL_HANDLERS = {
    "ask_hermes": tools.tool_ask_hermes,
    "start_session": tools.tool_start_session,
    "continue_session": tools.tool_continue_session,
    "list_sessions": tools.tool_list_sessions,
    "summarize_session": tools.tool_summarize_session,
    "delete_session": tools.tool_delete_session,
}


async def _heartbeat(
    *,
    session: Any,
    progress_token: str | int,
    related_request_id: str,
    tool_name: str,
) -> None:
    """Periodic progress notifier — runs until cancelled.

    Sends one notification every _HEARTBEAT_INTERVAL_SECONDS so the
    client's `resetTimeoutOnProgress` timer keeps refreshing. The
    progress counter is monotonic seconds-elapsed; no `total` is
    supplied since we genuinely don't know how long Hermes will take
    (the whole point of the heartbeat).
    """
    elapsed = 0
    try:
        while True:
            await asyncio.sleep(_HEARTBEAT_INTERVAL_SECONDS)
            elapsed += int(_HEARTBEAT_INTERVAL_SECONDS)
            try:
                await session.send_progress_notification(
                    progress_token=progress_token,
                    progress=float(elapsed),
                    message=f"{tool_name}: Hermes still working ({elapsed}s)",
                    related_request_id=related_request_id,
                )
            except Exception:
                # If the client has gone away the send will fail; just
                # stop heartbeating — the main handler will discover the
                # closed stream when it tries to write its final result.
                logger.debug("heartbeat send failed for %s; stopping", tool_name)
                return
    except asyncio.CancelledError:
        # Normal path: main handler completed and cancelled us.
        raise


def build_app(cfg: Config) -> Starlette:
    server: Server = Server("hermes-mcp")
    store = SessionStore(cfg.db_path)
    client = HermesClient(cfg)

    @server.list_tools()
    async def _list() -> list[Tool]:
        return _TOOL_SCHEMAS

    @server.call_tool()
    async def _call(name: str, arguments: dict[str, Any]) -> list[TextContent]:
        handler = _TOOL_HANDLERS.get(name)
        if handler is None:
            return [TextContent(type="text", text=json.dumps({"error": f"unknown tool {name!r}"}))]

        # If the client supplied a progress token in `_meta.progressToken`,
        # spawn a background heartbeat that sends a `notifications/progress`
        # every _HEARTBEAT_INTERVAL_SECONDS. Claude-code (and any MCP client
        # honoring `resetTimeoutOnProgress: true`) resets its tool-call timer
        # on each notification, so a 20-minute Hermes run no longer trips the
        # client's MCP_TOOL_TIMEOUT.
        heartbeat_task: asyncio.Task[None] | None = None
        if name in _HEARTBEAT_TOOLS:
            try:
                ctx = server.request_context
            except LookupError:
                ctx = None
            if ctx is not None and ctx.meta is not None and ctx.meta.progressToken is not None:
                heartbeat_task = asyncio.create_task(
                    _heartbeat(
                        session=ctx.session,
                        progress_token=ctx.meta.progressToken,
                        related_request_id=str(ctx.request_id),
                        tool_name=name,
                    )
                )

        try:
            result = await handler(store, client, **arguments)
        except Exception as exc:
            logger.exception("tool %s failed", name)
            return [TextContent(type="text", text=json.dumps({"error": str(exc)}))]
        finally:
            if heartbeat_task is not None:
                heartbeat_task.cancel()
                try:
                    await heartbeat_task
                except (asyncio.CancelledError, Exception):
                    pass
        return [TextContent(type="text", text=json.dumps(result))]

    sse = SseServerTransport("/messages/")

    async def handle_sse(request: Request) -> None:
        async with sse.connect_sse(request.scope, request.receive, request._send) as streams:
            await server.run(streams[0], streams[1], server.create_initialization_options())

    async def startup() -> None:
        await store.init()
        logger.info("hermes-mcp ready: db=%s upstream=%s", cfg.db_path, cfg.hermes_api_url)

    async def shutdown() -> None:
        await client.aclose()

    return Starlette(
        routes=[
            Route("/sse", endpoint=handle_sse),
            Mount("/messages/", app=sse.handle_post_message),
        ],
        on_startup=[startup],
        on_shutdown=[shutdown],
    )


def run() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    cfg = Config.from_env()
    app = build_app(cfg)
    uvicorn.run(app, host=cfg.sse_host, port=cfg.sse_port, log_level="info")
    return 0
