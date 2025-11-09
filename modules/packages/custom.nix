{
  config,
  lib,
  pkgs,
  ...
}:

let
  dh = pkgs.stdenv.mkDerivation rec {
    name = "dh-${version}";
    version = "1.0";

    src = pkgs.writeTextFile {
      name = "dh.sh";
      text = ''
        #!/usr/bin/env bash

        if ! command -v zfs > /dev/null 2>&1; then
            echo "ERROR: ZFS not installed on this system"
            exit 1
        fi

        sort=""
        type="filesystem,volume"
        fields="name,used,refer,avail,compressratio,mounted"

        if [[ "$1" == "-u" ]]; then
            sort="-s used"
            shift
        elif [[ "$1" == "-s" ]]; then
            type="snapshot"
            fields="name,refer,creation"
            shift
        elif [[ "$1" == "-r" ]]; then
            sort="-s refer"
            shift
        fi

        exec zfs list -o $fields -t $type $sort "$@"
      '';
    };

    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      cp $src $out/bin/dh
      chmod +x $out/bin/dh
    '';

    meta = with lib; {
      description = "ZFS dataset helper - simplified zfs list command";
      license = licenses.mit;
      maintainers = with maintainers; [ jwiegley ];
    };
  };

  linkdups =
    with pkgs;
    stdenv.mkDerivation rec {
      name = "linkdups-${version}";
      version = "1.3";

      src = fetchFromGitHub {
        owner = "jwiegley";
        repo = "linkdups";
        rev = "57bb79332d3b79418692d0c974acba83a4fd3fc9";
        sha256 = "1d400vanbsrmfxf1w4na3r4k3nw18xnv05qcf4rkqajmnfrbzh3h";
      };

      phases = [
        "unpackPhase"
        "installPhase"
      ];

      installPhase = ''
        mkdir -p $out/bin
        cp -p linkdups $out/bin
      '';

      meta = {
        homepage = "https://github.com/jwiegley/linkdups";
        description = "A tool for hard-linking duplicate files";
        license = lib.licenses.mit;
        maintainers = with lib.maintainers; [ jwiegley ];
      };
    };
in
{
  environment.systemPackages =
    (with pkgs; [
      b3sum
      btop
      dh
      dig
      dirscan
      ethtool
      gh
      gnupg
      haskellPackages.sizes
      httm
      iperf3
      jq
      linkdups
      lsof
      mailutils
      nettools
      openssl
      pinentry-curses
      pv
      python3
      restic
      ripgrep
      socat
      sops
      task-master-ai
      tcpdump
      traceroute
      zfs-prune-snapshots
      llama-swap
      llama-cpp
    ])
    ++ [
      pkgs.dovecot-fts-flatcurve
    ];
}
