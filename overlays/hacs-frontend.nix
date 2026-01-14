{
  lib,
  buildPythonPackage,
  fetchurl,
}:

buildPythonPackage rec {
  pname = "hacs-frontend";
  version = "20250128065759";
  format = "wheel";

  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/6c/42/af2a204b462124f617727fd462fab243dd2aa01e1e202461daf810cda012/hacs_frontend-${version}-py3-none-any.whl";
    hash = "sha256-5rGWFx+8s8s+ztLEjnifPclGtZ90kEh98W2NTkeoX8Q=";
  };

  # No dependencies according to PyPI metadata
  propagatedBuildInputs = [ ];

  # Skip tests - this is just frontend assets
  doCheck = false;

  pythonImportsCheck = [ "hacs_frontend" ];

  meta = with lib; {
    description = "The frontend files of HACS";
    homepage = "https://github.com/hacs/frontend";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
  };
}
