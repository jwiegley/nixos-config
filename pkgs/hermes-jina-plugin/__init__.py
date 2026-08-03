"""Jina Reader extract plugin — user-installed, opt-in via plugins.enabled.

Provides the extract capability that the bundled SearXNG provider explicitly
lacks, without requiring one of the paid extract backends.

NOTE the RELATIVE import. The bundled plugins under plugins/web/<name>/ use an
absolute `from plugins.web.<name>.provider import ...`, which only resolves
because they sit inside that package. A user plugin in ~/.hermes/plugins/ has a
different anchor; hermes_cli.plugins loads it with spec_from_file_location and
sets submodule_search_locations + __package__, so the relative form is the one
that resolves in both places.
"""

from __future__ import annotations

from .provider import JinaWebProvider, install_availability_shim


def register(ctx) -> None:
    """Register the Jina Reader provider with the plugin context.

    The shim is NOT optional decoration — see install_availability_shim().
    Registration alone leaves the provider unreachable, because the extract
    dispatcher's availability check is a hardcoded name list that rejects
    every plugin it does not ship with.
    """
    ctx.register_web_search_provider(JinaWebProvider())
    install_availability_shim()
