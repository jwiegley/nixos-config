{ lib
, stdenv
, nodejs_20
, convention-speaker-list
, buildNpmPackage
}:

buildNpmPackage {
  pname = "convention-speaker-list";
  version = "1.0.0";

  src = convention-speaker-list;

  # npm workspace structure requires specific handling
  npmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # Will need to update this

  # Build all workspaces
  npmBuildScript = "build";

  # Skip npm install audit to avoid network calls during build
  npmInstallFlags = [ "--legacy-peer-deps" ];

  # Set NODE_ENV to production
  NODE_ENV = "production";

  buildPhase = ''
    runHook preBuild

    # Build shared package first
    npm run build:shared

    # Build backend
    npm run build:backend

    # Build frontend
    npm run build:frontend

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out

    # Copy package.json files
    cp package.json $out/
    cp backend/package.json $out/backend-package.json
    cp frontend/package.json $out/frontend-package.json
    cp shared/package.json $out/shared-package.json

    # Copy built backend
    cp -r backend/dist $out/backend

    # Copy backend source (needed for ts-node in production)
    cp -r backend/src $out/backend-src
    cp backend/tsconfig.json $out/backend-tsconfig.json

    # Copy built frontend
    cp -r frontend/dist $out/frontend

    # Copy built shared
    cp -r shared/dist $out/shared

    # Copy database migrations and scripts
    cp -r database $out/database

    # Copy node_modules for runtime
    cp -r node_modules $out/node_modules

    # Copy root tsconfig
    cp tsconfig.json $out/tsconfig.json

    runHook postInstall
  '';

  meta = with lib; {
    description = "Convention Speaker List Manager - Queue management system";
    homepage = "https://gitea.vulcan.lan/johnw/convention-speaker-list";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
