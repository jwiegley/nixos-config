# vaderSentiment: Valence Aware Dictionary and sEntiment Reasoner
# https://pypi.org/project/vaderSentiment/
#
# Old-style setup.py with install_requires = ['requests']. Note the
# camel-cased pname — that's the canonical PyPI name.
{
  lib,
  python,
  fetchPypi,
}:

python.pkgs.buildPythonPackage rec {
  pname = "vaderSentiment";
  version = "3.3.2";
  format = "setuptools";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-XXwG4Cf8i5kjjtsNU9lwz5cGbvl2VACYkLg3A4SWMvk=";
  };

  dependencies = with python.pkgs; [
    requests
  ];

  doCheck = false;

  pythonImportsCheck = [ "vaderSentiment" ];

  meta = with lib; {
    description = "VADER Sentiment Analysis";
    homepage = "https://github.com/cjhutto/vaderSentiment";
    license = licenses.mit;
  };
}
