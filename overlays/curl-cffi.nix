# curl-cffi: libcurl FFI bindings for Python with browser impersonation.
# Uses a pre-built manylinux wheel because it bundles curl-impersonate,
# which is complex to build from source.
# https://pypi.org/project/curl-cffi/
{
  lib,
  stdenv,
  buildPythonPackage,
  fetchurl,
  autoPatchelfHook,
  cffi,
  certifi,
}:

buildPythonPackage rec {
  pname = "curl-cffi";
  version = "0.14.0";
  format = "wheel";

  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/e2/07/a238dd062b7841b8caa2fa8a359eb997147ff3161288f0dd46654d898b4d/curl_cffi-0.14.0-cp39-abi3-manylinux_2_26_aarch64.manylinux_2_28_aarch64.whl";
    hash = "sha256-xC6Po8Zn25zNLmlu5Hrc081bCDjXKC8/xF9sDvPP36c=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [ stdenv.cc.cc.lib ];

  dependencies = [
    cffi
    certifi
  ];

  pythonImportsCheck = [ "curl_cffi" ];

  doCheck = false;

  meta = {
    description = "libcurl FFI bindings with browser impersonation support";
    homepage = "https://github.com/lexiforest/curl_cffi";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
  };
}
