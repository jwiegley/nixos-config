"""Local web extraction plugin — fully local, no external service.

Provides the extract capability that the bundled SearXNG provider explicitly
lacks, without a paid backend and without disclosing URLs to a third party.

NOTE the RELATIVE import. Bundled plugins under plugins/web/<name>/ use an
absolute `from plugins.web.<name>.provider import ...`, which resolves only
inside that package. This plugin is installed via services.hermes-agent
extraPlugins, which symlinks it into ~/.hermes/plugins/nix-managed-<name>;
hermes_cli.plugins loads that with spec_from_file_location and sets
submodule_search_locations + __package__, so the relative form is the one that
resolves.
"""

from __future__ import annotations

from .provider import LocalWebExtractProvider, install_availability_shim


def register(ctx) -> None:
    """Register the local extraction provider with the plugin context.

    The shim is NOT optional decoration — see install_availability_shim().
    Registration alone leaves the provider unreachable, because the extract
    dispatcher's availability check is a hardcoded name list that rejects every
    plugin it does not ship with.
    """
    ctx.register_web_search_provider(LocalWebExtractProvider())
    install_availability_shim()
