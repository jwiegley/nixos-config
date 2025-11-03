self: super: {

dirscan = with super; python3Packages.buildPythonPackage rec {
  pname = "dirscan";
  version = "2.0";
  format = "source";

  src = super.fetchFromGitHub {
    owner = "jwiegley";
    repo = "dirscan";
    rev = "c4f4823b1847ae6d1e2438d56677851e13de79fb";
    sha256 = "1zv1rrbcsi453bwp83xv6ldzsv149x5s1ankm8wd5bqfbq9gywsj";
    # date = "2025-11-02T23:43:30-08:00";
  };

  phases = [ "unpackPhase" "installPhase" ];

  installPhase = ''
    mkdir -p $out/bin $out/libexec
    cp dirscan.py $out/libexec
    python -mpy_compile $out/libexec/dirscan.py
    cp cleanup $out/bin
  '';

  meta = {
    homepage = https://github.com/jwiegley/dirscan;
    description = "Stateful directory scanning in Python";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ jwiegley ];
  };
};

}
