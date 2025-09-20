{ config, lib, pkgs, ... }:

{
  programs = {
    git.enable = true;
    htop.enable = true;
    tmux.enable = true;
    vim.enable = true;
  };
}
