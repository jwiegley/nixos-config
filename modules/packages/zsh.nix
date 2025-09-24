{ config, lib, pkgs, ... }:

{
  # Enable zsh system-wide
  programs.zsh = {
    enable = true;

    # Enable common features
    enableCompletion = true;
    enableBashCompletion = true;

    # History configuration
    histSize = 50000;
    histFile = "$HOME/.zsh_history";

    # Shell configuration
    shellInit = ''
      # Extended globbing
      setopt extended_glob

      # History settings
      setopt HIST_IGNORE_DUPS
      setopt SHARE_HISTORY
      setopt APPEND_HISTORY
      setopt EXTENDED_HISTORY
      setopt HIST_SAVE_NO_DUPS
      setopt HIST_REDUCE_BLANKS

      # Directory navigation
      setopt AUTO_CD
      setopt AUTO_PUSHD
      setopt PUSHD_IGNORE_DUPS
      setopt PUSHD_SILENT

      # Job control
      setopt NO_BG_NICE
      setopt NO_HUP
      setopt NO_LIST_BEEP
      setopt LOCAL_OPTIONS
      setopt LOCAL_TRAPS

      # Completion
      setopt COMPLETE_IN_WORD
      setopt ALWAYS_TO_END

      # Initialize z for directory jumping
      . ${pkgs.zsh-z}/share/z.sh
    '';

    # Interactive shell configuration
    interactiveShellInit = ''
      # Prompt configuration (if not using starship)
      if [[ $TERM == dumb || $TERM == emacs || ! -o interactive ]]; then
          unsetopt zle
          unset zle_bracketed_paste
          export PROMPT='$ '
          export RPROMPT=""
          export PS1='$ '
      fi

      # Key bindings
      bindkey '^T' transpose-chars
      bindkey '^A' beginning-of-line
      bindkey '^E' end-of-line
      bindkey '^K' kill-line
      bindkey '^U' kill-whole-line

      # Enable autosuggestions
      source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh

      # Enable syntax highlighting
      source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

      # FZF configuration
      if command -v fzf > /dev/null; then
        source ${pkgs.fzf}/share/fzf/key-bindings.zsh
        source ${pkgs.fzf}/share/fzf/completion.zsh

        # Custom FZF options
        export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --info=inline --border --exact"
        export FZF_CTRL_T_OPTS="--preview '(highlight -O ansi -l {} 2> /dev/null || cat {} || tree -C {}) 2> /dev/null | head -200'"
        export FZF_ALT_C_OPTS="--preview 'tree -C {} | head -200'"

        # Override Ctrl-T to not conflict with transpose-chars
        bindkey '^T' transpose-chars
      fi
    '';

    # Login shell configuration
    loginShellInit = ''
      # Set environment variables
      export CLICOLOR=yes
      export LESS="-FRSXM"
      export LESSCHARSET="utf-8"
      export PAGER="less"
      export WORDCHARS=""

      # Git prompt configuration (for non-starship users)
      export ZSH_THEME_GIT_PROMPT_CACHE="yes"
      export ZSH_THEME_GIT_PROMPT_CHANGED="%{$fg[yellow]%}%{✚%G%}"
      export ZSH_THEME_GIT_PROMPT_STASHED="%{$fg_bold[yellow]%}%{⚑%G%}"
      export ZSH_THEME_GIT_PROMPT_UPSTREAM_FRONT=" {%{$fg[yellow]%}"
    '';

    # Shell aliases
    shellAliases = {
      # Git shortcuts
      b = "git branch --color -v";
      l = "git log --graph --pretty=format:'%Cred%h%Creset —%Cblue%d%Creset %s %Cgreen(%cr)%Creset' --abbrev-commit --date=relative --show-notes=*";
      w = "git status -sb";
      good = "git bisect good";
      bad = "git bisect bad";
      ga = "git-annex";

      # File operations with safety
      rm = "${pkgs.rmtrash}/bin/rmtrash";
      wipe = "srm -vfr";
      rX = "chmod -R ugo+rX";
      scp = "rsync -aP --inplace";

      # System commands
      ls = "${pkgs.eza}/bin/eza --icons";
      ll = "${pkgs.eza}/bin/eza -la --icons";
      la = "${pkgs.eza}/bin/eza -a --icons";
      find = "${pkgs.fd}/bin/fd";
      par = "parallel";
      proc = "ps axwwww | grep -i";

      # Shortcuts
      vi = "vim";
      rehash = "hash -r";

      # NixOS specific
      rebuild = "sudo nixos-rebuild switch --flake /etc/nixos#vulcan";
      nixedit = "sudo -E \$EDITOR /etc/nixos";
    };
  };

  # Starship prompt configuration
  programs.starship = {
    enable = true;
    settings = {
      add_newline = true;
      scan_timeout = 10;

      # Symbol configuration
      aws.symbol = "  ";
      buf.symbol = " ";
      c.symbol = " ";
      cmake.symbol = " ";
      conda.symbol = " ";
      crystal.symbol = " ";
      dart.symbol = " ";
      directory.read_only = " 󰌾";
      docker_context.symbol = " ";
      elixir.symbol = " ";
      elm.symbol = " ";
      fennel.symbol = " ";
      fossil_branch.symbol = " ";
      git_branch.symbol = " ";
      git_commit.tag_symbol = "  ";
      golang.symbol = " ";
      guix_shell.symbol = " ";
      haskell.symbol = " ";
      haxe.symbol = " ";
      hg_branch.symbol = " ";
      hostname.ssh_symbol = " ";
      java.symbol = " ";
      julia.symbol = " ";
      kotlin.symbol = " ";
      lua.symbol = " ";
      memory_usage.symbol = "󰍛 ";
      meson.symbol = "󰔷 ";
      nim.symbol = "󰆥 ";
      nix_shell.symbol = " ";
      nodejs.symbol = " ";
      ocaml.symbol = " ";
      package.symbol = "󰏗 ";
      perl.symbol = " ";
      php.symbol = " ";
      pijul_channel.symbol = " ";
      python.symbol = " ";
      rlang.symbol = "󰟔 ";
      ruby.symbol = " ";
      rust.symbol = "󱘗 ";
      scala.symbol = " ";
      swift.symbol = " ";
      zig.symbol = " ";
      gradle.symbol = " ";

      os.symbols = {
        Alpaquita = " ";
        Alpine = " ";
        AlmaLinux = " ";
        Amazon = " ";
        Android = " ";
        Arch = " ";
        Artix = " ";
        CachyOS = " ";
        CentOS = " ";
        Debian = " ";
        DragonFly = " ";
        Emscripten = " ";
        EndeavourOS = " ";
        Fedora = " ";
        FreeBSD = " ";
        Garuda = "󰛓 ";
        Gentoo = " ";
        HardenedBSD = "󰞌 ";
        Illumos = "󰈸 ";
        Kali = " ";
        Linux = " ";
        Mabox = " ";
        Macos = " ";
        Manjaro = " ";
        Mariner = " ";
        MidnightBSD = " ";
        Mint = " ";
        NetBSD = " ";
        NixOS = " ";
        Nobara = " ";
        OpenBSD = "󰈺 ";
        openSUSE = " ";
        OracleLinux = "󰌷 ";
        Pop = " ";
        Raspbian = " ";
        Redhat = " ";
        RedHatEnterprise = " ";
        RockyLinux = " ";
        Redox = "󰀘 ";
        Solus = "󰠳 ";
        SUSE = " ";
        Ubuntu = " ";
        Unknown = " ";
        Void = " ";
        Windows = "󰍲 ";
      };
    };
  };

  # FZF configuration
  programs.fzf = {
    keybindings = true;
    fuzzyCompletion = true;
  };

  # Set environment variables that make sense for all zsh users
  environment.sessionVariables = {
    # Editor configuration
    EDITOR = "vim";
    VISUAL = "vim";

    # Locale settings
    LC_CTYPE = "en_US.UTF-8";

    # Color support
    LEDGER_COLOR = "true";
    CLICOLOR = "yes";
  };

  # Add zsh to valid login shells
  environment.shells = with pkgs; [ zsh ];
}
