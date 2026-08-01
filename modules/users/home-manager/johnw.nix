# NixOS-specific home-manager wrapper for John Wiegley.
#
# This imports the shared cross-platform module from nix-config and adds the
# small amount of policy specific to this headless server.

{
  inputs,
  ...
}:

{
  home-manager.users.johnw =
    {
      config,
      pkgs,
      hostname,
      ...
    }:
    let
      packages = import "${inputs.nix-config}/config/packages.nix" {
        inherit hostname inputs pkgs;
        isClientMachine = false;
      };
    in
    {
      imports = [ "${inputs.nix-config}/config/johnw.nix" ];

      home = {
        # NixOS-specific settings
        username = "johnw";
        homeDirectory = "/home/johnw";

        # Override EDITOR to vim on headless NixOS hosts
        sessionVariables.EDITOR = "vim";

        # NixOS-specific packages: shared cross-platform list + NixOS extras
        packages =
          packages.package-list
          ++ (with pkgs; [
            # Development tools
            apacheHttpd
            gcc
            gnumake
            nodejs
            python3
            uv

            # AI tools (droid/factory needs vips)
            vips
          ]);
      };

      programs = {
        gh.settings.editor = "vim";
        git.settings = {
          core.editor = "vim";
          tag.gpgsign = false;
        };
      };

      # claude-mem (Fix A + Fix B): the worker runs as a systemd *user* service,
      # which starts with a minimal env that doesn't inherit the login shell.
      # Restore PATH (so it finds uvx for chroma-mcp and the claude CLI) and
      # point LD_LIBRARY_PATH at nix-ld's curated lib set so chroma's manylinux
      # wheels can dlopen libstdc++.so.6 / libz.so.1. claude-mem owns the
      # .service unit, so manage only the .service.d/override.conf drop-in.
      # (Fix C / CLAUDE_CODE_PATH lives in the shared johnw.nix activation.)
      xdg.configFile."systemd/user/claude-mem-worker.service.d/override.conf".text = ''
        [Service]
        Environment=PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/run/wrappers/bin:${config.home.homeDirectory}/src/scripts
        Environment=LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib
      '';
    };
}
