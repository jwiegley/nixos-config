{
  lib,
  python312Packages,
}:
python312Packages.buildPythonApplication {
  pname = "open-source-secretary";
  version = "0.1.0";
  pyproject = true;

  # cleanSource drops .git/editor cruft but not Python bytecode caches, which
  # local test runs create; exclude them so the store hash is reproducible and
  # doesn't churn on transient __pycache__/.pytest_cache state.
  src = lib.cleanSourceWith {
    src = lib.cleanSource ./.;
    filter =
      name: _type:
      let
        base = baseNameOf name;
      in
      !(base == "__pycache__" || base == ".pytest_cache" || lib.hasSuffix ".pyc" base);
  };

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
    platforms = platforms.linux;
  };
}
