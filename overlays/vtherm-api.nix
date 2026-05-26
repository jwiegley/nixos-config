# vtherm_api: Developer-facing API for the Versatile Thermostat HA integration.
# https://pypi.org/project/vtherm_api/
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
}:

buildPythonPackage rec {
  pname = "vtherm_api";
  version = "0.3.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-C6spKjWH/QAXcAYOcYg8okE1TFKPasS00zwGTiQ4sMM=";
  };

  build-system = [ setuptools ];

  # No pythonImportsCheck: vtherm_api imports `homeassistant` at module load,
  # which is only available inside HA's runtime, not the package build env.
  doCheck = false;

  meta = {
    description = "API of the Versatile Thermostat integration for Home Assistant";
    homepage = "https://github.com/jmcollin78/versatile_thermostat";
    license = lib.licenses.mit;
  };
}
