{
  lib,
  python,
  fetchFromGitHub,
}:

python.pkgs.buildPythonPackage rec {
  pname = "pandas-ta";
  version = "0.3.14b0";
  pyproject = true;
  disabled = python.pkgs.pythonOlder "3.7";

  src = fetchFromGitHub {
    owner = "twopirllc";
    repo = "pandas-ta";
    tag = "0.3.14";
    hash = "sha256-1s4/u0oN596VIJD94Tb0am3P+WGosRv9ihD+OIMdIBE=";
  };

  postPatch = ''
    substituteInPlace pandas_ta/momentum/squeeze_pro.py \
      --replace-fail "import NaN" "import nan"
    python - <<'PY'
    from pathlib import Path
    path = Path("pandas_ta/__init__.py")
    text = path.read_text()
    start = text.index("from pathlib import Path")
    end = text.index("\n\nImports =")
    replacement = "from importlib.metadata import version as distribution_version\n\nversion = __version__ = distribution_version(\"pandas_ta\")"
    path.write_text(text[:start] + replacement + text[end:])
    PY
  '';

  build-system = [ python.pkgs.setuptools ];
  dependencies = with python.pkgs; [
    numpy
    pandas
    python-dateutil
    pytz
    setuptools
    six
  ];
  doCheck = false;
  pythonImportsCheck = [ "pandas_ta" ];

  meta = {
    description = "Technical Analysis Indicators";
    homepage = "https://github.com/twopirllc/pandas-ta";
    license = lib.licenses.mit;
  };
}
