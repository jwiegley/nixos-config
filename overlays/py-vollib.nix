# py_vollib: Python library for calculating option prices, implied volatility
# and Greeks using Black, Black-Scholes, and Black-Scholes-Merton models.
# https://pypi.org/project/py-vollib/
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  numpy,
  scipy,
  pandas,
  simplejson,
  py_lets_be_rational,
}:

buildPythonPackage rec {
  pname = "py_vollib";
  version = "1.0.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-NudS7uFtz1KZTEKq9TcvCrnP0NKu3FRixMG2EjyezyA=";
  };

  build-system = [ setuptools ];

  dependencies = [
    py_lets_be_rational
    numpy
    scipy
    pandas
    simplejson
  ];

  pythonImportsCheck = [ "py_vollib" ];

  doCheck = false;

  meta = {
    description = "Options pricing and implied volatility (Black-Scholes, Black)";
    homepage = "https://github.com/vollib/py_vollib";
    license = lib.licenses.mit;
  };
}
