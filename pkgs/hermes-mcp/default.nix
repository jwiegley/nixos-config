{
  lib,
  python312,
  python312Packages,
}:
python312Packages.buildPythonApplication {
  pname = "hermes-mcp";
  version = "0.2.0";
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
    starlette
    uvicorn
    anyio
  ];

  # pytestCheckHook is what actually invokes pytest. Without it nixpkgs runs no
  # check phase at all: pytest/pytest-asyncio/respx are merely present in the
  # build environment and `pytestFlags` is inert, so the three test modules under
  # tests/ silently never ran. Verified on 2026-09-01 by listing the executed
  # phases -- there was no checkPhase between installPhase and fixupPhase.
  nativeCheckInputs = with python312Packages; [
    pytestCheckHook
    pytest-asyncio
    respx
  ];

  pytestFlags = [ "tests/" ];

  meta = with lib; {
    description = "MCP server bridging OpenClaw to Hermes Agent";
    homepage = "https://hermes-mcp.vulcan.lan";
    license = licenses.mit;
    mainProgram = "hermes-mcp";
  };
}
