{
  lib,
  python312,
  python312Packages,
}:
python312Packages.buildPythonApplication {
  pname = "hermes-mcp";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = with python312Packages; [
    setuptools
  ];

  dependencies = with python312Packages; [
    mcp
    httpx
    aiosqlite
    pydantic
  ];

  nativeCheckInputs = with python312Packages; [
    pytest
    pytest-asyncio
    respx
  ];

  pytestFlagsArray = [ "tests/" ];

  meta = with lib; {
    description = "MCP server bridging OpenClaw to Hermes Agent";
    homepage = "https://hermes-mcp.vulcan.lan";
    license = licenses.mit;
    mainProgram = "hermes-mcp";
  };
}
