# TEMPORARY home-manager compatibility shim — REMOVE when vulcan moves to
# nixos-26.05 / a home-manager that ships `programs.ssh.settings`.
#
# Why this exists
# ---------------
# The shared nix-config (config/ssh.nix, consumed via the `nix-config` flake
# input) was refactored to home-manager's newer `programs.ssh.settings` API:
# host patterns map to attrsets keyed by *PascalCase* ssh_config directive
# names (HostName, ForwardAgent, …), and `matchBlocks` became a deprecated
# alias for it. That option only exists in home-manager master. vulcan pins
# home-manager release-25.11, which ships only `programs.ssh.matchBlocks`
# (camelCase options + a freeform `extraOptions` = attrsOf str) and has *no*
# `settings` option — so eval fails with:
#   error: The option `home-manager.users.johnw.programs.ssh.settings' does not exist.
#
# What it does
# ------------
# 1. Declares a freeform `programs.ssh.settings` so nix-config's assignment
#    type-checks on release-25.11.
# 2. Translates each block into release-25.11's `programs.ssh.matchBlocks`:
#      • `header`  → the Host/Match head (host / match options).
#      • RemoteForward / LocalForward / DynamicForward / IdentityFile /
#        IdentityAgent / CertificateFile / SendEnv → the matching typed
#        listOf/forward option (value passed through unchanged — the forward
#        struct shape is identical between the two APIs).
#      • every other (scalar) directive → `extraOptions.<Directive>`, coercing
#        bool → "yes"/"no" and int → string (extraOptions is attrsOf str).
#    DAG-ordered values (`lib.hm.dag.entryAfter …`) are detected and re-wrapped
#    so ordering is preserved (matchBlocks is itself a DAG).
#
# Removal: when home-manager provides `programs.ssh.settings` natively, delete
# this file and drop it from johnw.nix's imports — the upstream option then
# takes over (this stub would otherwise collide with it).
{ config, lib, ... }:

let
  cfg = config.programs.ssh.settings;

  # Directives whose values are lists/structures and therefore cannot be
  # expressed through `extraOptions` (attrsOf str): route to the typed option.
  structuredOption = {
    RemoteForward = "remoteForwards";
    LocalForward = "localForwards";
    DynamicForward = "dynamicForwards";
    IdentityFile = "identityFile";
    IdentityAgent = "identityAgent";
    CertificateFile = "certificateFile";
    SendEnv = "sendEnv";
  };
  # Of those, the typed options that are listOf str (a bare string value must
  # be wrapped into a singleton list to satisfy the type).
  listOfStrOption = [
    "identityFile"
    "identityAgent"
    "certificateFile"
    "sendEnv"
  ];

  scalarToStr = v: if lib.isBool v then (if v then "yes" else "no") else toString v;

  isDagEntry = v: lib.isAttrs v && v ? data && v ? after && v ? before;

  mkBlock =
    pattern: attrs:
    let
      header = attrs.header or null;
      hostMatch =
        if header == null then
          {
            host = pattern;
            match = null;
          }
        else if lib.hasPrefix "Match " header then
          {
            host = null;
            match = lib.removePrefix "Match " header;
          }
        else if lib.hasPrefix "Host " header then
          {
            host = lib.removePrefix "Host " header;
            match = null;
          }
        else
          {
            host = header;
            match = null;
          };

      directives = removeAttrs attrs [ "header" ];
      structured = lib.filterAttrs (k: _v: builtins.hasAttr k structuredOption) directives;
      scalars = lib.filterAttrs (k: v: !(builtins.hasAttr k structuredOption) && v != null) directives;

      structuredOpts = lib.mapAttrs' (
        k: v:
        let
          opt = structuredOption.${k};
        in
        lib.nameValuePair opt (
          if lib.elem opt listOfStrOption then
            (if lib.isList v then map toString v else [ (toString v) ])
          else
            v
        )
      ) structured;
    in
    {
      inherit (hostMatch) host match;
      extraOptions = lib.mapAttrs (_k: scalarToStr) scalars;
    }
    // structuredOpts;

  toMatchBlock =
    pattern: raw:
    if isDagEntry raw then
      lib.hm.dag.entryBetween (raw.after or [ ]) (raw.before or [ ]) (mkBlock pattern raw.data)
    else
      mkBlock pattern raw;
in
{
  options.programs.ssh.settings = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    visible = false;
    description = ''
      release-25.11 compatibility shim for the newer home-manager
      `programs.ssh.settings` API used by the shared nix-config. Translated
      into `programs.ssh.matchBlocks` by ssh-settings-compat.nix. Remove when
      home-manager ships `programs.ssh.settings` natively.
    '';
  };

  config.programs.ssh.matchBlocks = lib.mapAttrs toMatchBlock cfg;
}
