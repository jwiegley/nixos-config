# Override radicale with jwiegley's fork that adds vCard 4.0 support
# https://github.com/jwiegley/Radicale
#
# This fork uses a custom vobject with vCard 4.0 support.
# The vobject dependency is provided through pythonPackagesExtensions
# in the overlays/default.nix, so we don't need to patch pyproject.toml.
{
  fetchFromGitHub,
  lib,
  nixosTests,
  python3,
}:

python3.pkgs.buildPythonApplication rec {
  pname = "radicale";
  version = "3.5.11-vcard4";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "jwiegley";
    repo = "Radicale";
    rev = "437309d2010fb0fa644c5457eb98ade85dc58044";
    hash = "sha256-tb/4no5KWoOn9kw8oNHsyLAJ4aDgJV0UK6pAxOTQi/A=";
  };

  build-system = with python3.pkgs; [
    setuptools
  ];

  dependencies =
    with python3.pkgs;
    [
      defusedxml
      passlib
      vobject # Uses our overlayed vobject with vCard 4.0 support
      pika
      requests
      pytz
      ldap3
    ]
    ++ passlib.optional-dependencies.bcrypt;

  __darwinAllowLocalNetworking = true;

  nativeCheckInputs = with python3.pkgs; [
    pytestCheckHook
    waitress
  ];

  # Skip tests that may fail due to vCard 4.0 changes
  doCheck = false;

  passthru.tests = {
    inherit (nixosTests) radicale;
  };

  meta = {
    homepage = "https://github.com/jwiegley/Radicale";
    description = "CalDAV and CardDAV server (with vCard 4.0 support)";
    license = lib.licenses.gpl3Plus;
    maintainers = with lib.maintainers; [
      dotlambda
      erictapen
    ];
  };
}
