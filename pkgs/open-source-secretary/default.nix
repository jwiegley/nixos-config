{
  lib,
  python312Packages,
}:
python312Packages.buildPythonApplication {
  pname = "open-source-secretary";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = with python312Packages; [ setuptools ];
  dependencies = with python312Packages; [ requests ];
  nativeCheckInputs = with python312Packages; [
    pytestCheckHook
    responses
  ];
  pytestFlagsArray = [ "tests/" ];

  meta = with lib; {
    description = "Daily GitHub/Gitea issue+PR triage report via Hermes Agent";
    license = licenses.mit;
    mainProgram = "oss-secretary";
  };
}
