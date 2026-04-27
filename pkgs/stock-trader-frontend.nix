# stock-trader-frontend: build of the React 19 + Vite SPA shipped in
# `web/` of the laptop repo. Output is a static-bundle directory layout
# (index.html + assets/...) ready to be served by FastAPI's StaticFiles.
#
# The npm package root is the `web/` subdirectory of the repo; we use
# `sourceRoot` so buildNpmPackage chdirs into it after unpacking.
{
  lib,
  buildNpmPackage,
  src,
  version,
}:

buildNpmPackage {
  pname = "stock-trader-frontend";
  inherit version src;

  # buildNpmPackage's auto-derived sourceRoot is `<src.name>/`; we want
  # the npm-rooted subdirectory below that. `src.name` for a flake input
  # outPath is `source` by default, so the chdir target is `source/web`.
  sourceRoot = "${src.name or "source"}/web";

  # `npm ci` will fetch the lockfile-pinned deps; npmDepsHash covers
  # all fetched npm packages. First-build path: leave the placeholder,
  # observe the `got:` value in the build error, paste it back.
  npmDepsHash = "sha256-boLb5fxDVl3jSHbD/06WlMRM25sa5uFszY1mJNoxgn4=";

  # `npm run build` runs `tsc -b && vite build`, writing to web/dist/.
  # Copy that into $out so consumers get a static-bundle layout at the
  # output root (no extra "dist/" prefix).
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r dist/* $out/
    runHook postInstall
  '';

  meta = with lib; {
    description = "stock-trader React SPA bundle";
    license = licenses.mit;
  };
}
