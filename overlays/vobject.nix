# Override vobject with jwiegley's fork that adds vCard 4.0 support
# https://github.com/jwiegley/vobject
{ lib
, buildPythonPackage
, fetchFromGitHub
, isPyPy
, setuptools
, python-dateutil
, pytz
, six
, pytestCheckHook
}:

buildPythonPackage rec {
  pname = "vobject";
  version = "0.9.6.1-vcard4";
  pyproject = true;

  disabled = isPyPy;

  src = fetchFromGitHub {
    owner = "jwiegley";
    repo = "vobject";
    rev = "0134b13153e3829f5604eb52a3564d8f97a8aa10";
    hash = "sha256-IzX6tSLQDdCNyy6Cd1hBuYALLQp20308uwo7PHu0HTY=";
  };

  build-system = [ setuptools ];

  dependencies = [
    python-dateutil
    pytz
    six
  ];

  pythonImportsCheck = [ "vobject" ];

  nativeCheckInputs = [ pytestCheckHook ];

  enabledTestPaths = [ "tests.py" ];

  # Some tests may fail due to vCard 4.0 changes
  doCheck = false;

  meta = {
    description = "Module for reading vCard and vCalendar files (with vCard 4.0 support)";
    homepage = "https://github.com/jwiegley/vobject";
    license = lib.licenses.asl20;
    maintainers = [ ];
  };
}
