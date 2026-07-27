final: prev: {

  # ⚠ INERT as of 2026-07-27: this overrides the TOP-LEVEL `check_systemd`
  # attribute, which nixos-25.11 has renamed away — evaluating
  # `pkgs.check_systemd` now throws "'check_systemd' has been renamed to/
  # replaced by 'nagiosPlugins.check_systemd'". Nothing forces that attribute,
  # so nothing fails, but the patch below never reaches the plugin Nagios
  # actually runs: modules/services/nagios.nix:1324 and :2513 use
  # `pkgs.nagiosPlugins.check_systemd` (upstream 5.0.0, unpatched). To make
  # this effective again the override has to target `nagiosPlugins`.
  #
  # Patch check-systemd to support 'reload-notify' sub-state
  #
  # This is a transient state that occurs during reload operations for
  # Type=notify services
  #
  # The upstream package doesn't include this state in the SubState Literal
  # type, causing Nagios checks to fail with "Invalid sub state:
  # reload-notify"

  #
  # Issue: Type=notify services enter reload-notify during reloads
  # Solution: Add 'reload-notify' to the SubState type definition
  #
  # Reference: https://github.com/Josef-Friedrich/check_systemd/issues
  check_systemd = prev.check_systemd.overrideAttrs (oldAttrs: {
    # Add patch to insert 'reload-notify' into the SubState Literal type
    # The state should be added after 'reload' at line 171
    postPatch = (oldAttrs.postPatch or "") + ''
        echo "Patching check_systemd.py to add 'reload-notify' sub-state support"

        # Add 'reload-notify' after 'reload' in the SubState Literal type
        # Line 171 contains: "reload",
        # We insert: "reload-notify", after it
        substituteInPlace check_systemd.py \
          --replace-fail '"reload",' '"reload",
      "reload-notify",'
    '';

    meta = oldAttrs.meta // {
      description = oldAttrs.meta.description + " (patched for reload-notify support)";
    };
  });
}
