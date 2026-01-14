{
  lib,
  buildHomeAssistantComponent,
  fetchFromGitHub,
}:

buildHomeAssistantComponent rec {
  owner = "dwradcliffe";
  domain = "intellicenter";
  version = "2.0.0";

  src = fetchFromGitHub {
    owner = "dwradcliffe";
    repo = "intellicenter";
    rev = "v${version}";
    hash = "sha256-HhWcHg4TNXxNfw0/FQoJr6gFkYlN758pwgh/UFBwB9A=";
  };

  meta = with lib; {
    description = "Home Assistant Integration for Pentair IntelliCenter";
    homepage = "https://github.com/dwradcliffe/intellicenter";
    changelog = "https://github.com/dwradcliffe/intellicenter/releases/tag/v${version}";
    license = licenses.gpl3Only;
    maintainers = with maintainers; [ ];
  };
}
