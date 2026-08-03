import logging
import threading
from typing import Any, Dict, List

from agent.memory_provider import MemoryProvider

from .config import DEFAULTS, load_config, save_plugin_config
from .embeddings import FastEmbedEmbedder, embedder_from_config
from .extraction import extract
from .retrieval import format_prefetch
from .retrieval import recall as recall_memories
from .store import QdrantStore, content_hash, stable_turn_id, utc_now
from .tools import TOOL_SCHEMAS, QdrantToolDispatcher

logger = logging.getLogger(__name__)


class QdrantMemoryProvider(MemoryProvider):
    """Hybrid vector + sparse memory backed by an embedded Qdrant collection."""

    def __init__(self) -> None:
        self._config: Dict[str, Any] = load_config()
        self._session_id: str = ""
        self._hermes_home: str = ""
        self._platform: str = ""
        self._agent_context: str = "primary"
        self._agent_identity: str = ""
        self._agent_workspace: str = ""
        self._user_id: str = ""
        self._message_index: int = 0
        self._initialized: bool = False
        self._embedder: FastEmbedEmbedder | None = None
        self._store: QdrantStore | None = None
        self._store_lock = threading.Lock()
        self._tool_dispatcher = QdrantToolDispatcher(self)
        self._prefetch_result = ""
        self._prefetch_lock = threading.Lock()
        self._prefetch_thread: threading.Thread | None = None

    @property
    def name(self) -> str:
        return "qdrant"

    @property
    def config(self) -> Dict[str, Any]:
        return self._config

    @property
    def workspace(self) -> str:
        return self._agent_workspace

    @property
    def user_id(self) -> str:
        return self._user_id

    @property
    def store(self) -> QdrantStore:
        if self._store is None:
            with self._store_lock:
                if self._store is None:
                    self._store = QdrantStore(
                        self._resolve_hermes_home(),
                        self._get_embedder(),
                        connection_cfg=self._config.get("connection") or {},
                    )
        return self._store

    def is_available(self) -> bool:
        """Verify hard dependencies are importable (no network calls).

        VENDORED EDIT. Upstream imports ``fastembed`` and ``qdrant_client``
        here. Neither exists in this build: fastembed is badPlatforms on
        aarch64-linux (see embeddings.py) and qdrant-client cannot be installed
        because its closure collides with the hermes sealed venv (see
        qdrant_rest.py). Both are replaced by httpx, which the sealed venv
        already provides.

        Keeping the upstream check would make this return False and the provider
        would never register -- and note the only trace would be the debug line
        below. That silent-disable is the whole reason this edit is called out.
        """
        try:
            import httpx  # noqa: F401
        except ImportError as exc:  # pragma: no cover - httpx is always present here
            logger.debug("qdrant provider not available: %s", exc)
            return False
        return True

    def initialize(self, session_id: str, **kwargs) -> None:
        self._config = load_config()
        self._session_id = session_id
        self._hermes_home = str(kwargs.get("hermes_home") or self._resolve_hermes_home())
        self._platform = str(kwargs.get("platform") or "")
        self._agent_context = str(kwargs.get("agent_context") or "primary")
        self._agent_identity = str(kwargs.get("agent_identity") or "")
        self._agent_workspace = str(kwargs.get("agent_workspace") or "")
        self._user_id = str(kwargs.get("user_id") or "")
        self._message_index = 0
        self._get_embedder().warm()
        self.store.start_worker()
        self._initialized = True
        logger.info(
            "qdrant provider initialized (session=%s, platform=%s, agent_identity=%s)",
            session_id,
            self._platform or "?",
            self._agent_identity or "?",
        )

    def system_prompt_block(self) -> str:
        return (
            "# Qdrant Memory\n"
            "Active. Recall durable workspace memory with qdrant_recall. "
            "Use qdrant_remember when the user explicitly asks you to remember "
            "something important. Use qdrant_read for full content/provenance. "
            "For forgetting, preview candidates with qdrant_forget before deleting "
            "one exact ID."
        )

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        # Non-blocking: return whatever the background recall has ready. A slow
        # fetch surfaces on the next turn rather than stalling this one.
        with self._prefetch_lock:
            result = self._prefetch_result
            self._prefetch_result = ""
        return result

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        if not query or not self._initialized:
            return

        if self._prefetch_thread and self._prefetch_thread.is_alive():
            return

        def _run() -> None:
            try:
                rows = self.recall(
                    query,
                    mode=self._config["retrieval"].get("mode", "vector"),
                    kind="fact",
                    limit=min(int(self._config["retrieval"].get("top_k", 10)), 5),
                )
                if not rows:
                    rows = self.recall(query, mode="vector", kind="turn", limit=3)
                formatted = format_prefetch(rows)
                if formatted:
                    with self._prefetch_lock:
                        self._prefetch_result = formatted
            except Exception as exc:
                logger.debug("qdrant prefetch failed: %s", exc)

        self._prefetch_thread = threading.Thread(target=_run, daemon=True, name="qdrant-prefetch")
        self._prefetch_thread.start()

    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "") -> None:
        if not self._should_write():
            return
        sid = session_id or self._session_id
        user_row = self._build_turn_row("user", user_content, sid)
        assistant_row = self._build_turn_row("assistant", assistant_content, sid)
        self.store.enqueue(user_row)
        self.store.enqueue(assistant_row)

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        return TOOL_SCHEMAS

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        return self._tool_dispatcher.handle(tool_name, args or {})

    def on_session_switch(
        self,
        new_session_id: str,
        *,
        parent_session_id: str = "",
        reset: bool = False,
        **kwargs,
    ) -> None:
        self._session_id = new_session_id
        if reset:
            self._message_index = 0
        for attr in ("agent_workspace", "agent_identity", "user_id"):
            if (v := kwargs.get(attr)) is not None:
                setattr(self, f"_{attr}", str(v))

    def on_memory_write(
        self,
        action: str,
        target: str,
        content: str,
        metadata: Dict[str, Any] | None = None,
    ) -> None:
        if action != "add" or not content or not self._should_write():
            return
        category = "preference" if target == "user" else "general"
        row = self.build_fact_row(
            content=content,
            abstract="",
            category=category,
            tags=[],
            provenance_turn_ids=[],
            source="memory_write_mirror",
        )
        if self.existing_fact(row):
            return
        self.store.enqueue(row)

    def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
        inserted = self._extract_and_store(messages, source="pre_compress")
        if not inserted:
            return ""
        lines = ["Qdrant extracted durable facts before compression:"]
        for row in inserted[:8]:
            lines.append(f"- {row['content']}")
        return "\n".join(lines)

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        self._extract_and_store(messages, source="session_end")

    def shutdown(self) -> None:
        if self._prefetch_thread and self._prefetch_thread.is_alive():
            self._prefetch_thread.join(timeout=2.0)
        if self._store is not None:
            self._store.shutdown()
        self._initialized = False
        logger.info("qdrant provider shutdown")

    def get_config_schema(self) -> List[Dict[str, Any]]:
        return [
            {
                "key": "retrieval_mode",
                "description": "Default recall mode",
                "default": self._config["retrieval"]["mode"],
                "choices": ["vector", "hybrid"],
            },
        ]

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        if values.get("retrieval_mode"):
            save_plugin_config({"retrieval": {"mode": values["retrieval_mode"]}}, hermes_home)

    def post_setup(self, hermes_home: str, config: Dict[str, Any]) -> None:
        import sys

        from hermes_cli.config import save_config

        if not self.is_available():
            print("\n  ⚠ Qdrant memory dependencies are not importable.")
            print(
                f"  Run manually: uv pip install --python {sys.executable} qdrant-client fastembed"
            )
            print("  Then re-run: hermes memory setup\n")
            return

        if not isinstance(config.get("memory"), dict):
            config["memory"] = {}
        config["memory"]["provider"] = "qdrant"
        save_config(config)
        # Defaults load from default_config.yaml at runtime. Don't copy them into
        # the user's config.yaml or a later default change can't reach them.

        embedding_cfg = DEFAULTS.get("embedding", {})
        api_key_env = embedding_cfg.get("api_key_env") or "OPENAI_API_KEY"
        try:
            dim = embedder_from_config(embedding_cfg).warm()
            print(f"\n  ✓ Qdrant memory configured (embedding dim: {dim})")
        except Exception as exc:
            print("\n  ✓ Qdrant memory configured")
            print(f"  ⚠ Embedding model warmup failed: {exc}")
            print(f"  Re-run setup or start a chat once {api_key_env} is set.")
        print("  Start a new session to activate.\n")

    def recall(
        self,
        query: str,
        *,
        mode: str = "",
        kind: str = "fact",
        category: str = "",
        limit: int | None = None,
    ) -> List[Dict[str, Any]]:
        retrieval_cfg = self._config.get("retrieval", {})
        return recall_memories(
            self.store,
            query,
            mode=mode or retrieval_cfg.get("mode", "vector"),
            kind=kind,
            category=category,
            workspace=self._agent_workspace,
            user_id=self._user_id,
            limit=limit if limit is not None else retrieval_cfg.get("top_k", 10),
        )

    def existing_fact(self, row: Dict[str, Any]) -> Dict[str, Any] | None:
        return self.store.find_by_hash(
            row["content_hash"],
            workspace=row.get("agent_workspace", ""),
            user_id=row.get("user_id", ""),
            kind="fact",
        )

    def _base_row(
        self,
        *,
        row_id: str,
        kind: str,
        content: str,
        content_hash_: str,
        session_id: str,
        source: str,
        role: str = "",
        turn_index: int = 0,
        abstract: str = "",
        category: str = "",
        tags: list[str] | None = None,
        provenance_turn_ids: list[str] | None = None,
    ) -> Dict[str, Any]:
        return {
            "id": row_id,
            "kind": kind,
            "content": content,
            "abstract": abstract,
            "category": category,
            "tags": tags or [],
            "provenance_turn_ids": provenance_turn_ids or [],
            "session_id": session_id,
            "turn_index": turn_index,
            "role": role,
            "user_id": self._user_id,
            "agent_identity": self._agent_identity,
            "agent_workspace": self._agent_workspace,
            "platform": self._platform,
            "source": source,
            "created_at": utc_now(),
            "content_hash": content_hash_,
        }

    def build_fact_row(
        self,
        *,
        content: str,
        abstract: str = "",
        category: str = "general",
        tags: list[str] | None = None,
        provenance_turn_ids: list[str] | None = None,
        source: str = "remember",
    ) -> Dict[str, Any]:
        ch = content_hash(
            content, workspace=self._agent_workspace, kind="fact", user_id=self._user_id
        )
        return self._base_row(
            row_id=f"fact_{ch[:32]}",
            kind="fact",
            content=content,
            content_hash_=ch,
            session_id=self._session_id,
            source=source,
            abstract=abstract,
            category=category or "general",
            tags=tags,
            provenance_turn_ids=provenance_turn_ids,
        )

    def _build_turn_row(self, role: str, content: str, session_id: str) -> Dict[str, Any]:
        message_index = self._message_index
        self._message_index += 1
        ch = content_hash(
            content, workspace=self._agent_workspace, kind="turn", user_id=self._user_id
        )
        return self._base_row(
            row_id=stable_turn_id(session_id, role, content),
            kind="turn",
            content=content,
            content_hash_=ch,
            session_id=session_id,
            source="sync_turn",
            role=role,
            turn_index=message_index,
        )

    def _extract_and_store(
        self, messages: List[Dict[str, Any]], *, source: str
    ) -> list[dict[str, Any]]:
        if not self._should_write() or not self._config.get("extraction", {}).get("enabled", True):
            return []
        min_turns = int(self._config.get("extraction", {}).get("min_turns", 3))
        user_turns = sum(1 for msg in messages if msg.get("role") == "user")
        if user_turns < min_turns:
            return []
        facts = extract(messages, self._context())
        inserted = []
        for fact in facts:
            provenance_ids = self._evidence_to_turn_ids(messages, fact.get("evidence") or [])
            row = self.build_fact_row(
                content=fact["content"],
                abstract=fact.get("abstract", ""),
                category=fact.get("category", "general"),
                tags=fact.get("tags", []),
                provenance_turn_ids=provenance_ids,
                source=source,
            )
            if self.existing_fact(row):
                continue
            self.store.add_row(row)
            inserted.append(row)
        return inserted

    def _evidence_to_turn_ids(
        self, messages: List[Dict[str, Any]], evidence: list[int]
    ) -> list[str]:
        ids = []
        for idx in evidence:
            if idx < 0 or idx >= len(messages):
                continue
            msg = messages[idx]
            role = str(msg.get("role") or "")
            content = str(msg.get("content") or "")
            if role not in {"user", "assistant"} or not content:
                continue
            ids.append(stable_turn_id(self._session_id, role, content))
        return ids

    def _context(self) -> Dict[str, Any]:
        return {
            "session_id": self._session_id,
            "platform": self._platform,
            "agent_identity": self._agent_identity,
            "agent_workspace": self._agent_workspace,
            "user_id": self._user_id,
        }

    def _should_write(self) -> bool:
        return self._agent_context not in {"cron", "subagent", "flush"}

    def _get_embedder(self) -> FastEmbedEmbedder:
        if self._embedder is None:
            self._embedder = embedder_from_config(self._config.get("embedding", {}))
        return self._embedder

    def _resolve_hermes_home(self) -> str:
        if self._hermes_home:
            return self._hermes_home
        try:
            from hermes_constants import get_hermes_home

            return str(get_hermes_home())
        except Exception:
            from pathlib import Path

            return str(Path.home() / ".hermes")
