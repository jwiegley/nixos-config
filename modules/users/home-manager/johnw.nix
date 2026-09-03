# NixOS-specific home-manager wrapper for John Wiegley.
#
# This imports the shared cross-platform module from nix-config and adds the
# small amount of policy specific to this headless server.

{
  inputs,
  lib,
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

      # AI harnesses this server does not run.
      harnesses = [
        "codex"
        "gemini"
        "gemini-cli"
        "google-gemini-cli"
        "droid"
        "factory-cli"
      ];
      isHarness =
        package:
        let
          name = package.name or "";
        in
        lib.any (harness: name == harness || lib.hasPrefix "${harness}-" name) harnesses;
    in
    {
      imports = [
        "${inputs.nix-config}/config/johnw.nix"

        # The harnesses do not all come from packages.package-list: config/ai.nix
        # adds codex and droid through its own home.packages definition, and
        # hard-asserts that both packages exist, so there is no upstream knob to
        # switch them off. They therefore have to be filtered out of the *merged*
        # list. Doing that with mkForce on this module's own definition would
        # discard every other module's contribution as well -- which is exactly
        # what dropped agent-deck, obr, plasma-wiki, git, man, starship, pi and
        # the language servers on 2026-09-03. An `apply` runs after the merge
        # instead, so every other definition still lands in the profile.
        #
        # home.packages declares no `apply` of its own, so this declaration
        # merges with home-manager's rather than colliding with it.
        { options.home.packages = lib.mkOption { apply = lib.filter (package: !isHarness package); }; }
      ];

      home = {
        # NixOS-specific settings
        username = "johnw";
        homeDirectory = "/home/johnw";

        # Override EDITOR to vim on headless NixOS hosts
        sessionVariables.EDITOR = "vim";

        # NixOS-specific packages: shared cross-platform list + NixOS extras.
        # Merged with the shared modules' own contributions; the harness filter
        # is applied to the merged result by the option declaration above.
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
