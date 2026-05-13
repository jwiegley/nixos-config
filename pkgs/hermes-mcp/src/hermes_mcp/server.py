"""SSE MCP server exposing the six hermes-mcp tools."""
from __future__ import annotations

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
        try:
            result = await handler(store, client, **arguments)
        except Exception as exc:
            logger.exception("tool %s failed", name)
            return [TextContent(type="text", text=json.dumps({"error": str(exc)}))]
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
