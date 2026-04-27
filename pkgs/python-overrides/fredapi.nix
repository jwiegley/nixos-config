# fredapi: Python API for the St. Louis Fed's FRED economic data
# https://pypi.org/project/fredapi/
#
# Old-style setup.py with install_requires = ['pandas']. Build with the
# legacy setuptools format, not pyproject — the upstream sdist has no
# pyproject.toml.
{
  lib,
  python,
  fetchPypi,
}:

python.pkgs.buildPythonPackage rec {
  pname = "fredapi";
  version = "0.5.2";
  format = "setuptools";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-QFygSKvtQgfZPbybfujEbWtHNINlAyPi8cCUr4PUskc=";
  };

  dependencies = with python.pkgs; [
    pandas
  ];

  doCheck = false;

  pythonImportsCheck = [ "fredapi" ];

  meta = with lib; {
    description = "Python API for the Federal Reserve Economic Data (FRED)";
    homepage = "https://github.com/mortada/fredapi";
    license = licenses.mit;
  };
}
