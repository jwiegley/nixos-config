# NixOS-specific home-manager wrapper for John Wiegley.
#
# This imports the shared cross-platform module from nix-config (the
# Darwin repository, accessed via Gitea as a non-flake input) and adds
# NixOS-specific packages and overrides.

{
  system,
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.johnw =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ "${inputs.nix-config}/config/johnw.nix" ];

      home = {
        # NixOS-specific settings
        username = "johnw";
        homeDirectory = "/home/johnw";

        # Override EDITOR to vim on headless NixOS hosts
        sessionVariables.EDITOR = lib.mkForce "vim";

        # NixOS-specific packages
        packages = with pkgs; [
          inputs.org-jw.packages.${system}.default

          # Development tools
          apacheHttpd
          gcc
          gnumake
          nodejs
          python3
          uv

          # AI tools (droid/factory needs vips)
          opencode
          vips
        ];
      };

      # Override gh editor to vim on NixOS
      programs.gh.settings.editor = lib.mkForce "vim";

      # Override git core editor to vim on NixOS
      programs.git.settings.core.editor = lib.mkForce "vim";
    };
}
