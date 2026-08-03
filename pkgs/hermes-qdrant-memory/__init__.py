"""Qdrant memory provider — plugin entry point.

VENDORED EDIT. Upstream branches on ``if not __package__`` and uses a plain
relative import (``from .src.qdrant import QdrantMemoryProvider``) whenever
__package__ is set. That relative import CANNOT WORK for a user-installed
memory provider on hermes-agent 0.15.1, because of an upstream bug in the
loader:

    plugins/memory/__init__.py:_load_provider_from_dir() loads a user plugin as
    ``_hermes_user_memory.<dirname>`` and pre-registers the parent packages
    ``plugins`` and ``plugins.memory`` -- but never registers
    ``_hermes_user_memory`` itself. So resolving any relative import raises
    ``ModuleNotFoundError: No module named '_hermes_user_memory'``.

The failure is SILENT: exec_module's exception is logged at DEBUG, the loader
returns None, and the only visible trace at INFO is

    Memory provider '<name>' loaded but no provider instance found

which says nothing about the cause. Diagnosed by reproducing the loader by hand
on 2026-08-03. The bundled providers are unaffected because their parent
(``plugins.memory``) IS registered.

Fix: always take upstream's synthetic-package path, which registers a real
top-level package name pointing at this directory and imports through THAT
instead of through the broken ``_hermes_user_memory`` parent. Submodules inside
src/ then resolve normally, because src is a genuine subpackage of the synthetic
package.

NOTE the literal tokens ``MemoryProvider`` and ``register_memory_provider`` must
stay within the first 8192 bytes of this file: both
plugins/memory/__init__.py:_is_memory_provider_dir() and
hermes_cli/plugins.py's kind-coercion do a raw source text scan for them, and
losing them would make this plugin invisible (again, silently).
"""

import importlib
import sys
from pathlib import Path

# A real, importable, dot-free top-level name. Deliberately NOT derived from the
# install directory: extraPlugins names that directory
# "nix-managed-hermes-qdrant-memory", and hyphens are not valid in a Python
# module path.
_PACKAGE_NAME = "hermes_agent_memory_qdrant"

_package = sys.modules.setdefault(_PACKAGE_NAME, sys.modules[__name__])
# __path__ is what makes "<pkg>.src.qdrant" resolvable from this directory.
if not getattr(_package, "__path__", None):
    _package.__path__ = [str(Path(__file__).resolve().parent)]

QdrantMemoryProvider = importlib.import_module(f"{_PACKAGE_NAME}.src.qdrant").QdrantMemoryProvider


def register(ctx) -> None:
    """Register the provider. Called with a _ProviderCollector by the loader."""
    ctx.register_memory_provider(QdrantMemoryProvider())


__all__ = ["QdrantMemoryProvider", "register"]
