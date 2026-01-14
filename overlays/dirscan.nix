self: super: {

  dirscan =
    with super;
    python3Packages.buildPythonPackage rec {
      pname = "dirscan";
      version = "2.0";
      format = "source";

      src = super.fetchFromGitHub {
        owner = "jwiegley";
        repo = "dirscan";
        rev = "fbfe86782187c9cacf7c098963a8ccad346312b1";
        sha256 = "1gmxcjpwgpqkp4awgldaf8yzz1lhynfrj6qnfs4f5dllmi90ycmm";
        # date = "2025-11-13";
      };

      phases = [
        "unpackPhase"
        "installPhase"
      ];

      installPhase = ''
        mkdir -p $out/bin $out/libexec
        cp dirscan.py $out/libexec
        python -mpy_compile $out/libexec/dirscan.py
        cp cleanup $out/bin
        cp share.py $out/bin
      '';

      meta = {
        homepage = "https://github.com/jwiegley/dirscan";
        description = "Stateful directory scanning in Python";
        license = lib.licenses.mit;
        maintainers = with lib.maintainers; [ jwiegley ];
      };
    };

}
