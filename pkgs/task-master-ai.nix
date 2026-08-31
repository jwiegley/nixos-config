{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
  nodejs_22,
  versionCheckHook,
}:

(buildNpmPackage.override { nodejs = nodejs_22; }) {
  pname = "task-master-ai";
  version = "0.25.1";

  src = fetchFromGitHub {
    owner = "eyaltoledano";
    repo = "claude-task-master";
    tag = "task-master-ai@0.25.1";
    hash = "sha256-7Vs8k8/ym2K+FzX3fAke344S9gEhjPCnzz1z+OlounE=";
  };

  npmDepsHash = "sha256-6dPIZtbTmLVrJgaSAZE7pT1+xbKVkBS+UF8xfy/micc=";
  dontNpmBuild = true;
  npmFlags = [ "--ignore-scripts" ];
  makeWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath [ nodejs_22 ]}" ];

  postInstall = ''
    mkdir -p $out/lib/node_modules/task-master-ai/apps
    cp -r apps/extension $out/lib/node_modules/task-master-ai/apps/extension
    cp -r apps/docs $out/lib/node_modules/task-master-ai/apps/docs
  '';

  env.PUPPETEER_SKIP_DOWNLOAD = 1;
  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;
  versionCheckProgram = "${placeholder "out"}/bin/task-master";
}
