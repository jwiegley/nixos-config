"""Embeddings for the Qdrant memory provider — REWRITTEN for vulcan.

Upstream computes both dense and sparse vectors LOCALLY with ``fastembed``
(ONNX Runtime). That is unusable here for two independent reasons:

1. ``python3Packages.fastembed`` carries
   ``meta.badPlatforms = [ "aarch64-linux" ]`` in the pinned nixpkgs AND in
   nixpkgs-unstable HEAD, with the comment
   ``# terminate called after throwing an instance of 'onnxruntime::OnnxRuntimeException'``.
   Floating the pin does not fix it.
2. Even if it built, ``initialize()`` calls ``warm()``, which would run ONNX
   inference inside the Hermes guest on every memory write and recall. This host
   is explicitly not allowed to run model inference; hera serves models.

So dense vectors come from the LLM gateway's OpenAI-compatible
``/v1/embeddings`` — the same endpoint, and the same 127.0.0.1:4000 two-stage
DNAT path, the agent already uses for chat. No new port, no new dependency
(``httpx`` is in the sealed venv), no local inference. The gateway's nginx layer
injects the upstream Authorization header, so no credential is needed here.

Sparse vectors are computed locally, but with arithmetic rather than a model:
plain BM25 term-frequency components. See BM25Sparse for why that is sound
without corpus statistics.
"""

from __future__ import annotations

import logging
import os
import re
import threading
import zlib
from collections import Counter
from typing import Any, Dict, List, Sequence, Tuple

logger = logging.getLogger(__name__)

# Matches the bridge/gateway default. models.nix embedding.primary is the single
# embedding model the backend serves; the Nix wrapper passes it explicitly.
DEFAULT_DENSE_MODEL = os.environ.get("HERMES_QDRANT_EMBED_MODEL", "bge-m3-mlx-fp16")
DEFAULT_SPARSE_MODEL = "bm25-local"

# Same base URL the agent uses for chat completions.
GATEWAY_BASE = os.environ.get(
    "HERMES_QDRANT_EMBED_BASE_URL",
    os.environ.get("OPENROUTER_BASE_URL", "http://127.0.0.1:4000/v1"),
).rstrip("/")

EMBED_TIMEOUT = float(os.environ.get("HERMES_QDRANT_EMBED_TIMEOUT", "60"))

# Batch cap. bge-m3 is a large model; a whole memory flush in one request can
# blow the backend's per-request budget, and one oversized request failing loses
# the entire batch rather than one chunk of it.
MAX_BATCH = int(os.environ.get("HERMES_QDRANT_EMBED_BATCH", "32"))

_TOKEN_RE = re.compile(r"[a-z0-9]+")

# BM25 constants. k1/b are the standard defaults. AVG_LEN is a FIXED assumed
# average document length: with no corpus statistics we cannot compute a real
# one, and fastembed's own Bm25 does the same thing for the same reason. It only
# affects length normalisation, and identically at index and query time.
BM25_K1 = 1.2
BM25_B = 0.75
BM25_AVG_LEN = 256.0


class BM25Sparse:
    """Stateless BM25 sparse vectoriser.

    Emits only the term-frequency component of BM25. The inverse-document-
    frequency half is applied by QDRANT, because the sparse vector index is
    created with ``modifier="idf"`` (see qdrant_rest.SparseVectorParams). That
    split is what makes this stateless: no vocabulary, no document counts, no
    state to keep consistent between index and query time.

    Token -> index uses ``zlib.crc32``, NOT the builtin ``hash()``. ``hash()``
    is salted per process (PYTHONHASHSEED), so a memory written by one agent
    process would be unqueryable by the next one — a silent recall failure that
    would look like "memory isn't working" with nothing in the logs.

    NOTE this is deliberately NOT wire-compatible with fastembed's
    ``Qdrant/bm25``. It only has to agree with itself. A collection previously
    populated by upstream-with-fastembed could not be sparse-queried by this
    code; that is irrelevant here because the collection is created fresh.
    """

    def __init__(self, avg_len: float = BM25_AVG_LEN) -> None:
        self.avg_len = avg_len

    @staticmethod
    def _tokenize(text: str) -> List[str]:
        # Length >= 2 drops the single-character noise that otherwise dominates
        # the hash space without carrying retrieval signal.
        return [t for t in _TOKEN_RE.findall((text or "").lower()) if len(t) >= 2]

    @staticmethod
    def _index(token: str) -> int:
        # 31-bit: Qdrant sparse indices are unsigned, and staying under 2^31
        # avoids any signedness ambiguity in JSON round-tripping.
        return zlib.crc32(token.encode("utf-8")) & 0x7FFFFFFF

    def encode(self, text: str) -> Tuple[List[int], List[float]]:
        tokens = self._tokenize(text)
        if not tokens:
            # Qdrant rejects a sparse vector with empty indices, and upstream's
            # callers expect a usable pair, so emit a single inert term.
            return [0], [0.0]
        counts = Counter(tokens)
        doc_len = len(tokens)
        norm = BM25_K1 * (1.0 - BM25_B + BM25_B * (doc_len / self.avg_len))
        merged: Dict[int, float] = {}
        for token, tf in counts.items():
            weight = (tf * (BM25_K1 + 1.0)) / (tf + norm)
            idx = self._index(token)
            # crc32 collisions are rare but must not silently drop a term;
            # summing is the same thing the term appearing twice would do.
            merged[idx] = merged.get(idx, 0.0) + weight
        indices = sorted(merged)
        return indices, [merged[i] for i in indices]


class GatewayEmbedder:
    """Dense embeddings from the LLM gateway; sparse computed locally.

    Keeps upstream's FastEmbedEmbedder method surface exactly, so store.py and
    retrieval.py need no changes: dim, warm, embed_one, embed, embed_sparse,
    embed_sparse_batch.
    """

    def __init__(
        self,
        model_name: str = DEFAULT_DENSE_MODEL,
        *,
        sparse_model_name: str = DEFAULT_SPARSE_MODEL,
        base_url: str = GATEWAY_BASE,
        **_: Any,
    ) -> None:
        self.model_name = model_name or DEFAULT_DENSE_MODEL
        self.sparse_model_name = sparse_model_name or DEFAULT_SPARSE_MODEL
        self.base_url = (base_url or GATEWAY_BASE).rstrip("/")
        self._dim: int | None = None
        self._sparse = BM25Sparse()
        self._lock = threading.Lock()
        self._client = None

    # -- dense -------------------------------------------------------------

    def _http(self):
        if self._client is None:
            with self._lock:
                if self._client is None:
                    import httpx

                    self._client = httpx.Client(timeout=EMBED_TIMEOUT)
        return self._client

    def _post_batch(self, texts: Sequence[str]) -> List[List[float]]:
        resp = self._http().post(
            f"{self.base_url}/embeddings",
            json={"model": self.model_name, "input": list(texts)},
        )
        if resp.status_code >= 400:
            raise RuntimeError(
                f"embedding gateway HTTP {resp.status_code}: {resp.text[:300]}"
            )
        payload = resp.json()
        data = payload.get("data")
        if not isinstance(data, list) or len(data) != len(texts):
            raise RuntimeError(
                f"embedding gateway returned {len(data) if isinstance(data, list) else 'no'} "
                f"vectors for {len(texts)} input(s)"
            )
        # Sort by index: the OpenAI schema does not promise response order, and
        # a silently permuted batch would attach each memory to the wrong vector
        # — corrupt recall with no error anywhere.
        ordered = sorted(data, key=lambda d: d.get("index", 0))
        return [list(d["embedding"]) for d in ordered]

    def embed(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        clean = [t if t else " " for t in texts]
        out: List[List[float]] = []
        for start in range(0, len(clean), MAX_BATCH):
            out.extend(self._post_batch(clean[start : start + MAX_BATCH]))
        return out

    def embed_one(self, text: str) -> List[float]:
        return self.embed([text])[0]

    @property
    def dim(self) -> int:
        if self._dim is None:
            self._dim = len(self.embed_one("dim probe"))
            logger.info("qdrant memory: dense dim=%d via %s", self._dim, self.base_url)
        return self._dim

    def warm(self) -> int:
        """Resolve the vector dimension.

        Unlike upstream this loads no model — it is a single small gateway call,
        which also serves as an early, loud check that the gateway is reachable
        before any memory write is attempted.
        """
        return self.dim

    # -- sparse ------------------------------------------------------------

    def embed_sparse(self, text: str) -> tuple[list[int], list[float]]:
        return self._sparse.encode(text)

    def embed_sparse_batch(self, texts: list[str]) -> list[tuple[list[int], list[float]]]:
        return [self._sparse.encode(t if t else " ") for t in (texts or [])]


# Upstream name kept as an alias so any stray reference still resolves.
FastEmbedEmbedder = GatewayEmbedder


def embedder_from_config(embedding_cfg: Dict[str, Any] | None) -> GatewayEmbedder:
    cfg = embedding_cfg or {}
    return GatewayEmbedder(
        cfg.get("model") or DEFAULT_DENSE_MODEL,
        sparse_model_name=cfg.get("sparse_model") or DEFAULT_SPARSE_MODEL,
        base_url=cfg.get("base_url") or GATEWAY_BASE,
    )
