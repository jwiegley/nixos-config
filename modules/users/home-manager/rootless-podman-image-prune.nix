# Rootless podman image prune (Home Manager sharedModule)
#
# WHY THIS EXISTS
# ---------------
# Our rootless container services (open-webui, teable, changedetection,
# openproject, ...) track *moving* image tags (e.g. ghcr.io/open-webui/open-webui
# :main-stable). Every time a newer image is pulled, the tag moves to the new image
# and the previous one is orphaned as a dangling <none> image. Podman never removes
# these on its own, so each per-user overlay store grows without bound.
#
# 2026-06-01 audit: /var/lib/containers had ballooned to ~194G, almost entirely
# dangling images (one service alone held 25 dangling copies = 46G of 48G). Pruning
# reclaimed ~150G.
#
# WHY virtualisation.podman.autoPrune (set in modules/containers/quadlet.nix) DOESN'T
# COVER THIS: that option generates `podman-prune.service` which runs `podman system
# prune --all` *as root*, against root's graphroot (/var/lib/containers/storage).
# Our containers are ROOTLESS — each runs under its own `systemd --user` manager with
# storage under /var/lib/containers/<user>/.local/share/containers/storage. The
# root-level timer never touches those per-user stores. This module closes that gap.
#
# MECHANISM
# ---------
# Installed into every Home Manager user via `home-manager.sharedModules`
# (see ./default.nix). It self-targets the rootless container users by matching
# `home.homeDirectory` against the /var/lib/containers/ prefix, so it applies to all
# of them and never to johnw (/home/johnw) — no user list to keep in sync. The timer
# runs in the user's own session, so podman automatically uses that user's graphroot,
# exactly like the manual `podman image prune` we verified on 2026-06-01.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  config = lib.mkIf (lib.hasPrefix "/var/lib/containers/" config.home.homeDirectory) {
    systemd.user.services.podman-image-prune = {
      Unit.Description = "Prune unused rootless podman images";
      Service = {
        Type = "oneshot";
        # --all also removes tagged-but-unused images; in-use images (referenced by
        # any running or stopped container) are always kept, so this can never break
        # a live container — it just reclaims old/dangling layers. Mirrors the
        # `--all` semantics of the root-level autoPrune in quadlet.nix.
        ExecStart = "${pkgs.podman}/bin/podman image prune --all --force";
      };
    };

    systemd.user.timers.podman-image-prune = {
      Unit.Description = "Weekly rootless podman image prune";
      Timer = {
        OnCalendar = "weekly";
        # Run after a missed window (e.g. host was down at the scheduled time).
        Persistent = true;
        # Spread the ~14 per-user timers out so they don't all hit disk at once.
        RandomizedDelaySec = "1h";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
