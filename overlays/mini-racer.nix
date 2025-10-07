{
  lib,
  buildPythonPackage,
  fetchurl,
  pythonOlder,
}:

buildPythonPackage rec {
  pname = "mini-racer";
  version = "0.12.4";
  format = "wheel";

  disabled = pythonOlder "3.8";

  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/9c/a1/09122c88a0dd0a2141b0ea068d70f5d31acd0015d6f3157b8efd3ff7e026/mini_racer-${version}-py3-none-manylinux_2_31_x86_64.whl";
    hash = "sha256-aaHETQKpBpuIFoTO8VotdH/gdD3ynq3Igf2nACquX9I=";
  };

  # The package includes pre-built V8 binaries, so we skip tests
  # that would require building from source
  doCheck = false;

  pythonImportsCheck = [ "py_mini_racer" ];

  meta = with lib; {
    description = "Minimal, modern embedded V8 for Python";
    homepage = "https://github.com/bpcreech/PyMiniRacer";
    changelog = "https://github.com/bpcreech/PyMiniRacer/blob/${version}/HISTORY.md";
    license = licenses.isc;
    maintainers = with maintainers; [ ];
  };
}
