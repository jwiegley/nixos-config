# overlays/30-agent-deck.nix
# Purpose: agent-deck - Terminal (tmux) session manager for AI coding agents
# Dependencies: Uses prev only
# Packages: agent-deck
#
# NOTE: This is a local mirror of ai-nix's overlays/30-agent-deck.nix. The
# shared nix-config package list already pulls in `agent-deck` via
# `optPkg "agent-deck"`, which resolves it from `pkgs`. It would normally be
# provided by the ai-nix overlay, but this host pins ai-nix to 4690e999 — the
# last rev whose llama-cpp overlay is compatible with our nixpkgs pin (see the
# ai-nix input comment in flake.nix). agent-deck landed in ai-nix well after
# that (5b1fb96), so bumping the pin to get it would reintroduce the llama-cpp
# eval breakage. The package is fully self-contained (buildGoModule, prev only),
# so it is cheaper and safer to mirror the definition here than to advance the
# pin. Drop this file and rely on the ai-nix overlay once the nixpkgs pin moves
# past the llama-cpp webui-in-tools/ui change and ai-nix can be unpinned.
_final: prev: {

  agent-deck =
    with prev;
    # ai-nix builds this against its own (newer) nixpkgs, whose default `go`
    # already satisfies agent-deck's `go 1.25.11` go.mod directive. This host
    # pins nixpkgs to nixos-25.11, whose default `go` is 1.25.10 — one patch too
    # old — so the stock buildGoModule fails with "go.mod requires go >= 1.25.11
    # (running go 1.25.10; GOTOOLCHAIN=local)". Pin the toolchain to go_1_26
    # (1.26.4, the smallest release available in this pin that satisfies the
    # directive, and cached so it is not built from source). Go is backwards
    # compatible and the toolchain version does not affect the vendored-module
    # hash, so vendorHash is unchanged from ai-nix.
    (buildGoModule.override { go = go_1_26; }) rec {
      pname = "agent-deck";
      version = "1.9.73";

      src = fetchFromGitHub {
        owner = "asheshgoplani";
        repo = "agent-deck";
        tag = "v${version}";
        hash = "sha256-4LbeRiaFIn4Nx/VtDvhJAaeA7YB6i2VX8wZhJ75qw5k=";
      };

      vendorHash = "sha256-teB9HxMGOe5YGW0RGxVOhkDPyczCDdjATRV9Mn9ixDU=";

      # Only the user-facing TUI/CLI. cmd/agent-deck-test-server is a test helper
      # and is not shipped by upstream (goreleaser builds cmd/agent-deck alone).
      subPackages = [ "cmd/agent-deck" ];

      # Pure Go: SQLite is modernc.org/sqlite, so no cgo is needed. Matches
      # upstream's goreleaser build (CGO_ENABLED=0) and keeps cross-platform
      # builds toolchain-free.
      env.CGO_ENABLED = "0";

      ldflags = [
        "-s"
        "-w"
        "-X"
        "main.Version=${version}"
      ];

      # The web UI's styles.css and every other //go:embed target are committed
      # artifacts, so the build needs no tailwind, npm, or go-generate step.

      # Upstream's test suite needs a real tmux, the race detector, and network
      # access, none of which exist in the Nix sandbox. Smoke-test the built
      # binary instead (mirrors the Homebrew formula's `agent-deck version`).
      doCheck = false;

      nativeBuildInputs = [ makeWrapper ];

      # agent-deck is a tmux session manager: tmux is a hard runtime requirement
      # (the binary exits at startup when it is missing), and git backs the
      # worktree and fork features. Use --suffix so a user's own tmux/git still
      # take precedence: that keeps the tmux client and server on the same binary
      # (a mismatched client/server pair fails with a protocol-version error when
      # the user runs `tmux attach` themselves) and honours this flake's policy of
      # not replacing the user's git. The store copies are only a fallback for a
      # machine that lacks them. Every other integration (jq, jujutsu, docker,
      # the clipboard tools, gh, and the agent CLIs themselves) is probed with
      # exec.LookPath and degrades gracefully, so those are left to the user PATH.
      postInstall = ''
        wrapProgram $out/bin/agent-deck \
          --suffix PATH : ${
            lib.makeBinPath [
              tmux
              git
            ]
          }
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        $out/bin/agent-deck version | grep -F "${version}"
        runHook postInstallCheck
      '';

      meta = with lib; {
        description = "Terminal session manager for AI coding agents (one tmux TUI for Claude, Codex, Gemini, OpenCode, and more)";
        homepage = "https://github.com/asheshgoplani/agent-deck";
        license = licenses.mit;
        mainProgram = "agent-deck";
        platforms = [
          "aarch64-darwin"
          "aarch64-linux"
          "x86_64-linux"
        ];
      };
    };

}
