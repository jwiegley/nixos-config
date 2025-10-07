{ lib, buildHomeAssistantComponent, fetchFromGitHub, python3Packages, hacs-frontend }:

buildHomeAssistantComponent rec {
  owner = "hacs";
  domain = "hacs";
  version = "2.0.5";

  src = fetchFromGitHub {
    owner = "hacs";
    repo = "integration";
    rev = version;
    hash = "sha256-xj+H75A6iwyGzMvYUjx61aGiH5DK/qYLC6clZ4cGDac=";
  };

  # Copy hacs_frontend into the HACS component directory for relative imports
  postPatch = ''
    cp -r ${hacs-frontend}/${python3Packages.python.sitePackages}/hacs_frontend custom_components/hacs/
    # Remove hacs_frontend's own dist-info to avoid manifest check issues
    rm -f custom_components/hacs/hacs_frontend/*.dist-info 2>/dev/null || true
  '';

  dependencies = [
    python3Packages.aiogithubapi
  ];

  meta = with lib; {
    description = "HACS gives you a powerful UI to handle downloads of all your custom needs";
    homepage = "https://hacs.xyz/";
    changelog = "https://github.com/hacs/integration/releases/tag/${version}";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
  };
}
