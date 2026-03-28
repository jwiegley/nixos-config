# requests-futures: Asynchronous HTTP requests using concurrent.futures.
# https://pypi.org/project/requests-futures/
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  requests,
}:

buildPythonPackage rec {
  pname = "requests-futures";
  version = "1.0.2";
  pyproject = true;

  src = fetchPypi {
    pname = "requests_futures";
    inherit version;
    hash = "sha256-a361eUAzboAPrrw9q1BjYO3slHj3si3FcIWK06p0WNo=";
  };

  build-system = [ setuptools ];

  dependencies = [ requests ];

  pythonImportsCheck = [ "requests_futures" ];

  doCheck = false;

  meta = {
    description = "Asynchronous HTTP requests using concurrent.futures";
    homepage = "https://github.com/ross/requests-futures";
    license = lib.licenses.asl20;
  };
}
