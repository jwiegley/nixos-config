self: super: {

dirscan = with super; python3Packages.buildPythonPackage rec {
  pname = "dirscan";
  version = "2.0";
  format = "source";

  src = super.fetchFromGitHub {
    owner = "jwiegley";
    repo = "dirscan";
    rev = "73378768709014a2ac97171c36a2287da79d09aa";
    sha256 = "02a1pr9msnxaydzdx7j7bnis54ylpccz9akbyri8yx2rgzgyvgm5";
    # date = "2025-11-03T17:26:54-08:00";
  };

  phases = [ "unpackPhase" "installPhase" ];

  installPhase = ''
    mkdir -p $out/bin $out/libexec
    cp dirscan.py $out/libexec
    python -mpy_compile $out/libexec/dirscan.py
    cp cleanup $out/bin
    cp share.py $out/bin
  '';

  meta = {
    homepage = https://github.com/jwiegley/dirscan;
    description = "Stateful directory scanning in Python";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ jwiegley ];
  };
};

}
