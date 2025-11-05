{ lib
, buildPythonPackage
, fetchPypi
, setuptools
, jinja2
, pillow
, mutagen
, argon2-cffi
, pyftpdlib
, pyopenssl
, pyzmq
}:

buildPythonPackage rec {
  pname = "copyparty";
  version = "1.19.20";
  format = "pyproject";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-rUNZTcz5N1vTqYpR4qjBvDYa4/KqutZGfZ476SM8rDQ=";
  };

  nativeBuildInputs = [
    setuptools
  ];

  # Core dependency
  propagatedBuildInputs = [
    jinja2
  ];

  # Optional dependencies for full functionality
  passthru.optional-dependencies = {
    thumbnails = [ pillow ];
    audiotags = [ mutagen ];
    pwhash = [ argon2-cffi ];
    ftps = [ pyftpdlib pyopenssl ];
    zeromq = [ pyzmq ];
  };

  # Skip tests - they require network access
  doCheck = false;

  pythonImportsCheck = [ "copyparty" ];

  meta = with lib; {
    description = "Portable file server with accelerated resumable uploads, dedup, WebDAV, FTP, TFTP, and media indexing";
    homepage = "https://github.com/9001/copyparty";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    mainProgram = "copyparty";
  };
}
