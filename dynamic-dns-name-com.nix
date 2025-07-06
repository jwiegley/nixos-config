{ lib, python3, python3Packages, fetchFromGitHub }:

let
  pythonPackage = python3.withPackages (
    python-pkgs: with python-pkgs; [
      requests
      pyyaml
      dateutil
    ]
  );

in python3Packages.buildPythonPackage rec {
  pname = "dynamic-dns-name-com";
  version = "unstable-2025-07-01";

  src = fetchFromGitHub {
    owner = "DanHerbert";
    repo = "dynamic-dns-name.com";
    rev = "2aa5e28458d8edd36120a5e77bacd113fa9ec75b";
    sha256 = "sha256-+kt5WW0WNu6GQuIG2zV9wv/hIERNdk8Tv7t3Y9U8RUo=";
  };

  propagatedBuildInputs = [ pythonPackage ];

  # No tests in upstream repo
  doCheck = false;
  pyproject = true;
  build-system = [ python3Packages.setuptools ];

  pythonImportsCheck = [ "dynip" ];

  patchPhase = ''
    substituteInPlace dynip.py \
      --replace 'CONFIG_PATH = os.path.join(SCRIPT_PATH, "config.yaml")' \
                'CONFIG_PATH = "/etc/dynamic-dns-name-com/config.yaml"' \
      --replace 'STATE_PATH = os.path.join(SCRIPT_PATH, "state.yaml")' \
                'STATE_PATH = "/var/lib/dynamic-dns-name-com/state.yaml"'

    substituteInPlace setup.py \
      --replace 'python-dateutil==2.8.2' 'python-dateutil>=2.8.2' \
      --replace 'pyyaml==6.0' 'pyyaml>=6.0' \
      --replace 'requests==2.31.0' 'requests>=2.31.0'
  '';

  postInstall = ''
    mkdir -p $out/bin
    makeWrapper ${pythonPackage}/bin/python $out/bin/dynip \
      --set PYTHONPATH \
            "$out/lib/python${pythonPackage.pythonVersion}/site-packages" \
      --add-flags "-m dynip"
  '';

  meta = with lib; {
    mainProgram = "dynip";
    description = "Dynamic DNS updater for name.com";
    homepage = "https://github.com/DanHerbert/dynamic-dns-name.com";
    license = licenses.mit;
    maintainers = [ ];
  };
}
