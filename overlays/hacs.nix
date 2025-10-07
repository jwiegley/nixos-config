{ lib, buildHomeAssistantComponent, fetchFromGitHub, python3Packages }:

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
