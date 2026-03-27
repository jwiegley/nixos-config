# py_lets_be_rational: Pure Python implementation of Peter Jaeckel's
# LetsBeRational implied-volatility algorithm.
# https://pypi.org/project/py-lets-be-rational/
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  numpy,
  scipy,
}:

buildPythonPackage rec {
  pname = "py_lets_be_rational";
  version = "1.0.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-DgeIpBCeECpmbybWcnbA08L+uKBZ54g1SpDlZfLbDtI=";
  };

  build-system = [ setuptools ];

  dependencies = [
    numpy
    scipy
  ];

  pythonImportsCheck = [ "py_lets_be_rational" ];

  # Tests not included in PyPI sdist
  doCheck = false;

  meta = {
    description = "Pure Python implementation of Peter Jaeckel's LetsBeRational";
    homepage = "https://github.com/vollib/py_lets_be_rational";
    license = lib.licenses.mit;
  };
}
