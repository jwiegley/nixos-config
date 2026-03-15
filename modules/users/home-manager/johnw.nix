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

      # Disable commit/tag GPG signing on this headless NixOS host.
      # The shared Darwin module enables signing by default (for macOS with
      # YubiKey), but this machine's GPG keybox is not populated and pcscd
      # is not configured here.
      programs.git.signing.signByDefault = lib.mkForce false;
      programs.git.settings.commit.gpgsign = lib.mkForce false;
      programs.git.settings.tag.gpgsign = lib.mkForce false;
    };
}
