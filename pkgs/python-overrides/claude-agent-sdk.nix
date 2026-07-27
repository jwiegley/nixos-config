# claude-agent-sdk: Python SDK for Claude Code
# https://pypi.org/project/claude-agent-sdk/
#
# Build deps from upstream pyproject.toml [project.dependencies]:
#   anyio>=4.0.0
#   typing_extensions>=4.0.0; python_version<'3.11'   (Python 3.12 — skip)
#   mcp>=0.1.0
#
# Tests are integration-heavy (subprocess to a real `claude` binary), so
# `doCheck = false`. `pythonImportsCheck` validates the import graph at
# build time, which is enough as a smoke test.
{
  lib,
  python,
  fetchPypi,
}:

python.pkgs.buildPythonPackage rec {
  pname = "claude-agent-sdk";
  # The PyPI sdist is named claude_agent_sdk-<version>.tar.gz. fetchPypi does
  # NO name normalization — it builds the URL verbatim from the pname it is
  # handed — so the underscored sdist name is passed to fetchPypi explicitly
  # below, while this derivation keeps the canonical hyphenated PyPI name.
  version = "0.1.30";
  pyproject = true;

  src = fetchPypi {
    pname = "claude_agent_sdk";
    inherit version;
    hash = "sha256-8WY5FDyH7i1du7luqEj5+8VCVqYABcPVXfmeSusNx3A=";
  };

  build-system = with python.pkgs; [
    hatchling
  ];

  dependencies = with python.pkgs; [
    anyio
    mcp
  ];

  doCheck = false;

  pythonImportsCheck = [ "claude_agent_sdk" ];

  meta = with lib; {
    description = "Python SDK for Claude Code (claude-agent-sdk)";
    homepage = "https://github.com/anthropics/claude-agent-sdk-python";
    license = licenses.mit;
  };
}
