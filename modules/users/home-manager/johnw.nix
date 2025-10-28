{ config, lib, pkgs, ... }:

{
  home-manager.users.johnw = { config, lib, pkgs, ... }:
  let
    home           = config.home.homeDirectory;
    tmpdir         = "/tmp";

    userName       = "John Wiegley";
    userEmail      = "johnw@newartisans.com";
    master_key     = "4710CF98AF9B327BB80F60E146C4BD1A7AC14BA2";
    signing_key    = "12D70076AB504679";

    external_host  = "home.newartisans.com";

    ca-bundle_path = "${pkgs.cacert}/etc/ssl/certs/";
    ca-bundle_crt  = "${ca-bundle_path}/ca-bundle.crt";
    emacs-server   = "${tmpdir}/johnw-emacs/server";
    emacsclient    = "${pkgs.emacs}/bin/emacsclient -s ${emacs-server}";
  in {
    # Home Manager version compatibility
    home.stateVersion = "24.11";

    # Basic home settings
    home.username = "johnw";
    home.homeDirectory = "/home/johnw";

    # Session variables
    home.sessionVariables = {
      ANTHROPIC_MODEL     = "opus";
      DISABLE_AUTOUPDATER = "1";
      B2_ACCOUNT_INFO     = "${config.xdg.configHome}/backblaze-b2/account_info";
      CABAL_CONFIG        = "${config.xdg.configHome}/cabal/config";
      CARGO_HOME          = "${config.xdg.dataHome}/cargo";
      CLICOLOR            = "yes";
      EDITOR              = "vim";  # Use vim on Linux by default
      EMACS_SERVER_FILE   = "${emacs-server}";
      EMAIL               = "${userEmail}";
      ET_NO_TELEMETRY     = "1";
      FONTCONFIG_FILE     = "${config.xdg.configHome}/fontconfig/fonts.conf";
      FONTCONFIG_PATH     = "${config.xdg.configHome}/fontconfig";
      GRAPHVIZ_DOT        = "${pkgs.graphviz}/bin/dot";
      GTAGSCONF           = "${pkgs.global}/share/gtags/gtags.conf";
      GTAGSLABEL          = "pygments";
      HOSTNAME            = "vulcan";  # NixOS hostname
      JAVA_OPTS           = "-Xverify:none";
      LESSHISTFILE        = "${config.xdg.cacheHome}/less/history";
      LITELLM_PROXY_URL   = "http://litellm.vulcan.lan";
      LLM_USER_PATH       = "${config.xdg.configHome}/llm";
      NIX_CONF            = "${home}/src/nix";
      NLTK_DATA           = "${config.xdg.dataHome}/nltk";
      PARALLEL_HOME       = "${config.xdg.cacheHome}/parallel";
      PROFILE_DIR         = "${config.home.profileDirectory}";
      RUSTUP_HOME         = "${config.xdg.dataHome}/rustup";
      SCREENRC            = "${config.xdg.configHome}/screen/config";
      SSL_CERT_FILE       = "${ca-bundle_crt}";
      STARDICT_DATA_DIR   = "${config.xdg.dataHome}/dictionary";
      TIKTOKEN_CACHE_DIR  = "${config.xdg.cacheHome}/tiktoken";
      TRAVIS_CONFIG_PATH  = "${config.xdg.configHome}/travis";
      TZ                  = "America/Los_Angeles";  # Match NixOS timezone
      VAGRANT_HOME        = "${config.xdg.dataHome}/vagrant";
      WWW_HOME            = "${config.xdg.cacheHome}/w3m";

      RCLONE_PASSWORD_COMMAND        = "${pkgs.pass}/bin/pass show Passwords/rclone";
      RESTIC_PASSWORD_COMMAND        = "${pkgs.pass}/bin/pass show Passwords/restic";
      FILTER_BRANCH_SQUELCH_WARNING  = "1";
      HF_HUB_ENABLE_HF_TRANSFER      = "1";
      LLAMA_INDEX_CACHE_DIR          = "${config.xdg.cacheHome}/llama-index";

      # This forces clearing the variable so home-manager can set it
      SSH_AUTH_SOCK = "";
    };

    # Session path
    home.sessionPath = [
      "${home}/src/scripts"
      "${home}/.local/bin"
      "/usr/local/bin"
    ];

    # Home files
    home.file = {
      ".ledgerrc".text = ''
        --file ${home}/doc/accounts/main.ledger
        --input-date-format %Y/%m/%d
        --date-format %Y/%m/%d
      '';

      ".curlrc".text = ''
        capath=${ca-bundle_path}
        cacert=${ca-bundle_crt}
      '';

      ".wgetrc".text = ''
        ca_directory = ${ca-bundle_path}
        ca_certificate = ${ca-bundle_crt}
      '';
    };

    # Programs configuration
    programs.home-manager.enable = true;

    programs.direnv = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
    };

    programs.htop.enable = true;
    programs.info.enable = true;
    programs.jq.enable = true;
    programs.man.enable = true;
    programs.vim.enable = true;

    programs.starship = {
      enable = true;
      settings = lib.mkMerge [
        (builtins.fromTOML
          (builtins.readFile
            "${pkgs.starship}/share/starship/presets/nerd-font-symbols.toml"))
        {
          add_newline = true;
          scan_timeout = 10;

          format = lib.concatStrings [
            "$all"
            "$directory"
            "$character"
          ];
        }
      ];

      enableBashIntegration = true;
      enableZshIntegration = true;
    };

    programs.tmux = {
      enable = true;
      extraConfig = ''
        set-option -g allow-passthrough on
        set-option -g default-shell ${pkgs.zsh}/bin/zsh
        set-option -g default-command ${pkgs.zsh}/bin/zsh
        set-option -g history-limit 250000
      '';
    };

    programs.browserpass = {
      enable = true;
      browsers = [ "firefox" ];
    };

    programs.fzf = {
      enable = true;
      enableZshIntegration = true;
      defaultOptions = [
        "--height 40%"
        "--layout=reverse"
        "--info=inline"
        "--border"
        "--exact"
      ];
    };

    programs.bash = {
      enable = true;
      bashrcExtra = lib.mkBefore ''
        source /etc/bashrc
      '';
    };

    programs.zsh = rec {
      dotDir = "${config.xdg.configHome}/zsh";

      enable = true;
      enableCompletion = false;

      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;

      history = {
        size       = 50000;
        save       = 500000;
        path       = "${config.xdg.configHome}/zsh/history";
        ignoreDups = true;
        share      = true;
        append     = true;
        extended   = true;
      };

      sessionVariables = {
        ALTERNATE_EDITOR = "${pkgs.vim}/bin/vi";
        LC_CTYPE         = "en_US.UTF-8";
        LEDGER_COLOR     = "true";
        LESS             = "-FRSXM";
        LESSCHARSET      = "utf-8";
        PAGER            = "less";
        WORDCHARS        = "";

        ZSH_THEME_GIT_PROMPT_CACHE = "yes";
        ZSH_THEME_GIT_PROMPT_CHANGED = "%{$fg[yellow]%}%{✚%G%}";
        ZSH_THEME_GIT_PROMPT_STASHED = "%{$fg_bold[yellow]%}%{⚑%G%}";
        ZSH_THEME_GIT_PROMPT_UPSTREAM_FRONT =" {%{$fg[yellow]%}";
      };

      localVariables = {
        RPROMPT        = "%F{green}%~%f";
        PROMPT         = "%B%m %b\\$(git_super_status)%(!.#.$) ";
        PROMPT_DIRTRIM = "2";
      };

      shellAliases = {
        vi     = "${pkgs.vim}/bin/vim";
        b      = "${pkgs.git}/bin/git b";
        l      = "${pkgs.git}/bin/git l";
        w      = "${pkgs.git}/bin/git w";
        ga     = "${pkgs.gitAndTools.git-annex}/bin/git-annex";
        good   = "${pkgs.git}/bin/git bisect good";
        bad    = "${pkgs.git}/bin/git bisect bad";
        par    = "${pkgs.parallel}/bin/parallel";
        rm     = "${pkgs.rmtrash}/bin/rmtrash";
        rX     = "${pkgs.coreutils}/bin/chmod -R ugo+rX";
        scp    = "${pkgs.rsync}/bin/rsync -aP --inplace";
        switch = "sudo nixos-rebuild switch --flake /etc/nixos#vulcan";
        proc   = "ps axwwww | grep -i";

        # Use whichever cabal is on the PATH.
        cb     = "cabal build";
        cn     = "cabal configure --enable-tests --enable-benchmarks";
        cnp    = "cabal configure --enable-tests --enable-benchmarks " +
                 "--enable-profiling --ghc-options=-fprof-auto";

        rehash = "hash -r";
      };

      profileExtra = ''
        . ${pkgs.zsh-z}/share/zsh-z/zsh-z.plugin.zsh
        setopt extended_glob
      '';

      initContent = ''
        # Make sure that fzf does not override the meaning of ^T
        bindkey '^T' transpose-chars
        bindkey -e

        if [[ $TERM == dumb || $TERM == emacs || ! -o interactive ]]; then
            unsetopt zle
            unset zle_bracketed_paste
            export PROMPT='$ '
            export RPROMPT=""
            export PS1='$ '
        else
            autoload -Uz compinit
            compinit
        fi
      '';
    };

    programs.password-store = {
      enable = true;
      package = pkgs.pass.withExtensions (exts: [
        exts.pass-otp
        exts.pass-genphrase
      ]);
      settings.PASSWORD_STORE_DIR = "${home}/doc/.password-store";
    };

    programs.gpg = {
      enable = true;
      homedir = "${config.xdg.configHome}/gnupg";
      settings = {
        use-agent = true;
        default-key = master_key;
        auto-key-locate = "keyserver";
        keyserver = "keys.openpgp.org";
        keyserver-options = "no-honor-keyserver-url include-revoked auto-key-retrieve";
      };
      scdaemonSettings = {
        card-timeout = "1";
        disable-ccid = true;
      };
    };

    programs.gh = {
      enable = true;
      settings = {
        editor = "vim";
        git_protocol = "ssh";
        aliases = {
          co = "pr checkout";
          pv = "pr view";
          prs = "pr list -A jwiegley";
        };
      };
    };

    programs.git = {
      enable = true;

      userName = "John Wiegley";
      userEmail = "johnw@newartisans.com";

      # signing = {
      #   key = signing_key;
      #   signByDefault = true;
      # };

      aliases = {
        amend      = "commit --amend -C HEAD";
        authors    = "!\"${pkgs.git}/bin/git log --pretty=format:%aN"
                   + " | ${pkgs.coreutils}/bin/sort"
                   + " | ${pkgs.coreutils}/bin/uniq -c"
                   + " | ${pkgs.coreutils}/bin/sort -rn\"";
        b          = "branch --color -v";
        ca         = "commit --amend";
        changes    = "diff --name-status -r";
        clone      = "clone --recursive";
        co         = "checkout";
        cp         = "cherry-pick";
        dc         = "diff --cached";
        dh         = "diff HEAD";
        ds         = "diff --staged";
        from       = "!${pkgs.git}/bin/git bisect start && ${pkgs.git}/bin/git bisect bad HEAD && ${pkgs.git}/bin/git bisect good";
        ls-ignored = "ls-files --exclude-standard --ignored --others";
        rc         = "rebase --continue";
        rh         = "reset --hard";
        ri         = "rebase --interactive";
        rs         = "rebase --skip";
        ru         = "remote update --prune";
        snap       = "!${pkgs.git}/bin/git stash"
                   + " && ${pkgs.git}/bin/git stash apply";
        snaplog    = "!${pkgs.git}/bin/git log refs/snapshots/refs/heads/"
                   + "\\$(${pkgs.git}/bin/git rev-parse HEAD)";
        spull      = "!${pkgs.git}/bin/git stash"
                   + " && ${pkgs.git}/bin/git pull"
                   + " && ${pkgs.git}/bin/git stash pop";
        su         = "submodule update --init --recursive";
        undo       = "reset --soft HEAD^";
        w          = "status -sb";
        wdiff      = "diff --color-words";
        l          = "log --graph --pretty=format:'%Cred%h%Creset"
                   + " —%Cblue%d%Creset %s %Cgreen(%cr)%Creset'"
                   + " --abbrev-commit --date=relative --show-notes=*";
      };

      extraConfig = {
        core = {
          editor            = "vim";
          trustctime        = false;
          pager             = "${pkgs.less}/bin/less --tabs=4 -RFX";
          logAllRefUpdates  = true;
          precomposeunicode = false;
          whitespace        = "trailing-space,space-before-tab";
          untrackedCache    = true;
        };

        branch.autosetupmerge  = true;
        commit.gpgsign         = false;
        commit.status          = false;
        github.user            = "jwiegley";
        credential.helper      = "${pkgs.pass-git-helper}/bin/pass-git-helper";
        hub.protocol           = "${pkgs.openssh}/bin/ssh";
        mergetool.keepBackup   = true;
        pull.rebase            = true;
        rebase.autosquash      = true;
        rerere.enabled         = false;
        init.defaultBranch     = "main";

        "merge \"ours\"".driver   = true;
        "magithub \"ci\"".enabled = false;

        http = {
          sslCAinfo = ca-bundle_crt;
          sslverify = true;
        };

        color = {
          status      = "auto";
          diff        = "auto";
          branch      = "auto";
          interactive = "auto";
          ui          = "auto";
          sh          = "auto";
        };

        push = {
          default = "tracking";
        };

        # "merge \"merge-changelog\"" = {
        #   name = "GNU-style ChangeLog merge driver";
        #   driver = "${pkgs.git-scripts}/bin/git-merge-changelog %O %A %B";
        # };

        merge = {
          conflictstyle = "diff3";
          stat = true;
        };

        "color \"sh\"" = {
          branch      = "yellow reverse";
          workdir     = "blue bold";
          dirty       = "red";
          dirty-stash = "red";
          repo-state  = "red";
        };

        annex = {
          backends = "BLAKE2B512E";
          alwayscommit = false;
        };

        "filter \"media\"" = {
          required = true;
          clean = "${pkgs.git}/bin/git media clean %f";
          smudge = "${pkgs.git}/bin/git media smudge %f";
        };

        diff = {
          ignoreSubmodules = "dirty";
          renames = "copies";
          mnemonicprefix = true;
        };

        advice = {
          statusHints = false;
          pushNonFastForward = false;
          objectNameWarning = "false";
        };

        "filter \"lfs\"" = {
          clean = "${pkgs.git-lfs}/bin/git-lfs clean -- %f";
          smudge = "${pkgs.git-lfs}/bin/git-lfs smudge --skip -- %f";
          required = true;
        };

        "url \"git://github.com/ghc/packages-\"".insteadOf = "git://github.com/ghc/packages/";
        "url \"http://github.com/ghc/packages-\"".insteadOf = "http://github.com/ghc/packages/";
        "url \"https://github.com/ghc/packages-\"".insteadOf = "https://github.com/ghc/packages/";
        "url \"ssh://git@github.com/ghc/packages-\"".insteadOf = "ssh://git@github.com/ghc/packages/";
        "url \"git@github.com:/ghc/packages-\"".insteadOf = "git@github.com:/ghc/packages/";
      };

      ignores = [
        "#*#"
        "*.a"
        "*.agdai"
        "*.aux"
        "*.dylib"
        "*.elc"
        "*.glob"
        "*.hi"
        "*.la"
        "*.lia.cache"
        "*.lra.cache"
        "*.nia.cache"
        "*.nra.cache"
        "*.o"
        "*.so"
        "*.v.d"
        "*.v.tex"
        "*.vio"
        "*.vo"
        "*.vok"
        "*.vos"
        "*~"
        ".*.aux"
        ".Makefile.d"
        ".clean"
        ".coq-native/"
        ".coqdeps.d"
        ".direnv/"
        ".envrc"
        ".envrc.cache"
        ".envrc.override"
        ".ghc.environment.x86_64-linux-*"
        ".makefile"
        ".pact-history"
        "TAGS"
        "cabal.project.local*"
        "default.hoo"
        "default.warn"
        "dist-newstyle/"
        "ghc[0-9]*_[0-9]*/"
        "input-haskell-*.tar.gz"
        "input-haskell-*.txt"
        "result"
        "result-*"
        "tags"
      ];
    };

    # XDG configuration
    xdg.enable = true;

    # News display
    news.display = "silent";

    # Packages to install for the user
    home.packages = with pkgs; [
      # Development tools
      gitAndTools.git-annex
      gitAndTools.git-workspace
      global
      claude-code

      # Shell enhancements
      zsh-z
      eza
      fd
      fzf
      parallel
      rmtrash
      starship
      zsh
      zsh-autosuggestions
      zsh-syntax-highlighting

      gcc
      gnumake
      python3
      uv
      nodejs
      vips                      # needed by fetch mcp server
    ];
  };
}
