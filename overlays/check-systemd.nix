final: prev: {

  # Patch check-systemd to support 'reload-notify' sub-state
  #
  # This is a transient state that occurs during reload operations for
  # Type=notify services
  #
  # The upstream package doesn't include this state in the SubState Literal
  # type, causing Nagios checks to fail with "Invalid sub state:
  # reload-notify"

  #
  # Issue: redis-n8n service (Type=notify) enters reload-notify during reloads
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
