{ config, lib, pkgs, ... }:

{
  programs = {
    git = {
      enable = true;
      config = {
        # Rewrite SSH URLs to HTTPS URLs for GitHub
        # This allows git-workspace to work with GITHUB_TOKEN authentication
        # even when repositories have submodules with SSH URLs
        url."https://github.com/".insteadOf = [
          "git@github.com:"
          "ssh://git@github.com/"
        ];
      };
    };
    htop.enable = true;
    tmux.enable = true;
    vim.enable = true;
  };
}
