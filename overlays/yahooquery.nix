# yahooquery: Python wrapper for Yahoo Finance API.
# Uses different endpoints than yfinance, avoiding the broken
# fc.yahoo.com cookie/crumb auth flow.
# https://pypi.org/project/yahooquery/
{
  lib,
  buildPythonPackage,
  fetchPypi,
  hatchling,
  beautifulsoup4,
  curl_cffi,
  lxml,
  pandas,
  requests-futures,
  tqdm,
}:

buildPythonPackage rec {
  pname = "yahooquery";
  version = "2.4.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-GQPGXq5qEtlelFAGNHkhbAeEbwE7riojkXkTUxt/rls=";
  };

  build-system = [ hatchling ];

  dependencies = [
    beautifulsoup4
    curl_cffi
    lxml
    pandas
    requests-futures
    tqdm
  ];

  pythonImportsCheck = [ "yahooquery" ];

  doCheck = false;

  meta = {
    description = "Python wrapper for Yahoo Finance API";
    homepage = "https://github.com/dpguthrie/yahooquery";
    license = lib.licenses.mit;
  };
}
