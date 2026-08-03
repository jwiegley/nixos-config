import hashlib
import logging
import os
import queue
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Optional

from .embeddings import FastEmbedEmbedder

logger = logging.getLogger(__name__)

COLLECTION = "memories"
SCHEMA_VERSION = 1


class _NullLock:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


_NULL_LOCK = _NullLock()


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def content_hash(content: str, *, workspace: str = "", kind: str = "", user_id: str = "") -> str:
    normalized = " ".join((content or "").strip().lower().split())
    payload = f"{kind}\0{workspace}\0{user_id}\0{normalized}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def stable_turn_id(session_id: str, role: str, content: str) -> str:
    digest = hashlib.sha256(f"{session_id}\0{role}\0{content}".encode("utf-8")).hexdigest()[:24]
    return f"turn_{digest}"


def to_qdrant_id(string_id: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_OID, string_id))


def build_filter(
    *,
    workspace: str = "",
    user_id: str = "",
    kind: str = "fact",
    category: str = "",
):
    from .qdrant_rest import FieldCondition, Filter, MatchValue

    must: list = []
    if kind and kind != "any":
        must.append(FieldCondition(key="kind", match=MatchValue(value=kind)))
    if workspace:
        must.append(FieldCondition(key="agent_workspace", match=MatchValue(value=workspace)))
    if user_id:
        # user_id = X OR user_id = '' to match workspace-global memories too
        must.append(
            Filter(
                should=[
                    FieldCondition(key="user_id", match=MatchValue(value=user_id)),
                    FieldCondition(key="user_id", match=MatchValue(value="")),
                ]
            )
        )
    if category:
        must.append(FieldCondition(key="category", match=MatchValue(value=category)))
    return Filter(must=must) if must else None


def _record_to_row(record) -> dict[str, Any]:
    payload = dict(record.payload or {})
    if "id_str" in payload:
        payload["id"] = payload["id_str"]
    if hasattr(record, "score") and record.score is not None:
        payload["_relevance_score"] = record.score
    return payload


def _in_scope(row: dict[str, Any], workspace: str, user_id: str) -> bool:
    # Mirror build_filter: workspace must match exactly. user_id matches the
    # caller or the workspace-global "" rows.
    if workspace and row.get("agent_workspace", "") != workspace:
        return False
    if user_id and row.get("user_id", "") not in (user_id, ""):
        return False
    return True


class QdrantStore:
    """Background-writer Qdrant store with dense + sparse named vectors."""

    def __init__(
        self,
        hermes_home: str | Path,
        embedder: FastEmbedEmbedder,
        *,
        connection_cfg: dict[str, Any] | None = None,
        collection: str = COLLECTION,
    ) -> None:
        self.hermes_home = Path(hermes_home).expanduser()
        self.embedder = embedder
        self._connection_cfg = connection_cfg or {}
        self.collection = collection
        self._client = None
        self._open_lock = threading.Lock()
        # Embedded (local) Qdrant is SQLite+numpy backed and NOT thread-safe.
        self._serialize_io = self._connection_cfg.get("mode", "local") != "remote"
        self._io_lock = threading.RLock()
        self._queue: queue.Queue[dict[str, Any] | None] = queue.Queue(maxsize=256)
        self._worker: threading.Thread | None = None
        self._closed = threading.Event()

    def io_guard(self):
        return self._io_lock if self._serialize_io else _NULL_LOCK

    @property
    def client(self):
        if self._client is None:
            self._open()
        return self._client

    def _open(self) -> None:
        if self._client is not None:
            return
        with self._open_lock:
            if self._client is not None:
                return
            self._open_locked()

    def _open_locked(self) -> None:
        from .qdrant_rest import QdrantClient
        from .qdrant_rest import (
            Distance,
            PayloadSchemaType,
            SparseVectorParams,
            VectorParams,
        )

        mode = self._connection_cfg.get("mode", "local")
        if mode == "remote":
            url = self._connection_cfg.get("url") or "http://localhost:6333"
            api_key_env = self._connection_cfg.get("api_key_env")
            api_key = None
            if api_key_env:
                api_key = os.environ.get(api_key_env)
                if not api_key:
                    logger.warning(
                        "qdrant api_key_env '%s' is set but the env var is empty. Connecting without auth",
                        api_key_env,
                    )
            # VENDORED ADDITION: api_key_file.
            #
            # This host already holds the Qdrant key as the SOPS secret
            # `qdrant/api-key`, staged into the guest as a 0400 hermes:hermes
            # file. Reading it here means there is exactly ONE copy of that
            # secret. The alternative -- adding QDRANT_API_KEY to the
            # `hermes/env` SOPS blob -- would create a second copy that silently
            # desyncs the next time the key is rotated, and would need an
            # interactive sops session to set up.
            #
            # Checked only when the env var produced nothing, so an explicit
            # api_key_env still wins and upstream behaviour is unchanged.
            if not api_key:
                api_key_file = self._connection_cfg.get("api_key_file")
                if api_key_file:
                    try:
                        api_key = Path(api_key_file).read_text().strip() or None
                    except OSError as exc:
                        logger.warning(
                            "qdrant api_key_file '%s' unreadable (%s). Connecting without auth",
                            api_key_file,
                            exc,
                        )
                    if api_key:
                        logger.info("qdrant api key loaded from file")
            self._client = QdrantClient(url=url, api_key=api_key)
            logger.info("qdrant client: remote (%s)", url)
        else:
            db_path = self._connection_cfg.get("path") or str(self.hermes_home / "qdrant")
            db_path = str(Path(db_path).expanduser())
            Path(db_path).mkdir(parents=True, exist_ok=True)
            self._client = QdrantClient(path=db_path)
            logger.info("qdrant client: local (%s)", db_path)

        existing = {c.name for c in self._client.get_collections().collections}
        if self.collection not in existing:
            self._client.create_collection(
                collection_name=self.collection,
                vectors_config={
                    "dense": VectorParams(size=self.embedder.dim, distance=Distance.COSINE)
                },
                sparse_vectors_config={"sparse": SparseVectorParams()},
            )
            for field in ("kind", "agent_workspace", "user_id", "category", "content_hash"):
                try:
                    self._client.create_payload_index(
                        self.collection, field, PayloadSchemaType.KEYWORD
                    )
                except Exception as exc:
                    logger.debug("create_payload_index(%s) skipped: %s", field, exc)
            logger.info(
                "qdrant collection '%s' created (dim=%d)", self.collection, self.embedder.dim
            )

    def start_worker(self) -> None:
        _ = self.client  # ensure open
        if self._worker and self._worker.is_alive():
            return
        self._closed.clear()
        self._worker = threading.Thread(target=self._worker_loop, daemon=True, name="qdrant-writer")
        self._worker.start()

    def enqueue(self, row: dict[str, Any]) -> None:
        try:
            self._queue.put_nowait(row)
        except queue.Full:
            logger.warning("qdrant writer queue full. Dropping memory row")

    def _worker_loop(self) -> None:
        batch: list[dict[str, Any]] = []

        def flush() -> None:
            if batch:
                self.add_rows(batch)
                batch.clear()

        while True:
            try:
                item = self._queue.get(timeout=0.25)
            except queue.Empty:
                # On timeout: flush any pending batch, then exit if shutdown was signaled.
                # Handles the case where None couldn't be enqueued (queue full during shutdown).
                flush()
                if self._closed.is_set():
                    return
                continue
            self._queue.task_done()
            if item is None:
                flush()
                return
            batch.append(item)
            if len(batch) >= 16:
                flush()

    def shutdown(self, timeout: float = 5.0) -> None:
        if self._worker and self._worker.is_alive():
            self._closed.set()
            try:
                self._queue.put_nowait(None)
            except queue.Full:
                pass
            self._worker.join(timeout=timeout)
        leftovers = []
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                break
            if item:
                leftovers.append(item)
        if leftovers:
            self.add_rows(leftovers)

    def add_rows(self, rows: list[dict[str, Any]]) -> None:
        if not rows:
            return
        self._open()
        points = self._prepare_rows(rows)
        if points:
            with self.io_guard():
                self.client.upsert(collection_name=self.collection, points=points)

    def add_row(self, row: dict[str, Any]) -> None:
        self.add_rows([row])

    def _prepare_rows(self, rows: list[dict[str, Any]]) -> list:
        from .qdrant_rest import PointStruct, SparseVector

        texts = [str(row.get("content") or "") for row in rows]
        dense_vecs = self.embedder.embed(texts)
        sparse_vecs = self.embedder.embed_sparse_batch(texts)
        points = []
        for row, dense_vec, (sparse_indices, sparse_values) in zip(rows, dense_vecs, sparse_vecs):
            payload = dict(row)
            payload.setdefault("id_str", payload["id"])
            payload.setdefault("schema_version", SCHEMA_VERSION)
            payload.setdefault("agent_workspace", "")
            payload.setdefault("user_id", "")
            if isinstance(payload.get("created_at"), datetime):
                payload["created_at"] = payload["created_at"].isoformat()
            points.append(
                PointStruct(
                    id=to_qdrant_id(payload["id_str"]),
                    vector={
                        "dense": dense_vec,
                        "sparse": SparseVector(indices=sparse_indices, values=sparse_values),
                    },
                    payload=payload,
                )
            )
        return points

    def get_by_id(
        self, memory_id: str, *, workspace: str = "", user_id: str = ""
    ) -> Optional[dict[str, Any]]:
        if not memory_id:
            return None
        with self.io_guard():
            results = self.client.retrieve(
                collection_name=self.collection,
                ids=[to_qdrant_id(memory_id)],
                with_payload=True,
                with_vectors=False,
            )
        if not results:
            return None
        row = _record_to_row(results[0])
        return row if _in_scope(row, workspace, user_id) else None

    def get_by_ids(
        self, ids: Iterable[str], *, workspace: str = "", user_id: str = ""
    ) -> list[dict[str, Any]]:
        clean = [str(v) for v in ids if v]
        if not clean:
            return []
        with self.io_guard():
            results = self.client.retrieve(
                collection_name=self.collection,
                ids=[to_qdrant_id(i) for i in clean],
                with_payload=True,
                with_vectors=False,
            )
        rows = [_record_to_row(r) for r in results]
        return [row for row in rows if _in_scope(row, workspace, user_id)]

    def find_by_hash(
        self, digest: str, *, workspace: str = "", user_id: str = "", kind: str = "fact"
    ) -> Optional[dict[str, Any]]:
        from .qdrant_rest import FieldCondition, Filter, MatchValue

        base = build_filter(workspace=workspace, user_id=user_id, kind=kind)
        hash_cond = FieldCondition(key="content_hash", match=MatchValue(value=digest))
        must = [hash_cond, *(base.must if base else [])]
        with self.io_guard():
            points, _ = self.client.scroll(
                collection_name=self.collection,
                scroll_filter=Filter(must=must),
                limit=1,
                with_payload=True,
                with_vectors=False,
            )
        return _record_to_row(points[0]) if points else None

    def delete_by_id(self, memory_id: str) -> None:
        from .qdrant_rest import PointIdsList

        with self.io_guard():
            self.client.delete(
                collection_name=self.collection,
                points_selector=PointIdsList(points=[to_qdrant_id(memory_id)]),
            )
