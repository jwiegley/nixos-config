# overlays/sherlock.nix
# Purpose: Sherlock - read-only database query tool for AI assistants
# Downloads pre-built binaries for aarch64-darwin and x86_64-linux.
# Builds from source using Bun for aarch64-linux (no pre-built binary available).
final: prev:

let
  version = "1.3.0";

  # Pre-built binary sources for platforms where official releases exist
  prebuiltSrcs = {
    aarch64-darwin = {
      url = "https://github.com/michaelbromley/sherlock/releases/download/v${version}/sherlock-darwin-arm64";
      hash = "sha256-l1dfzfjHDFhM9+Ro8E3jYJgSAYUOn898VUluoqGqKBw=";
    };
    x86_64-linux = {
      url = "https://github.com/michaelbromley/sherlock/releases/download/v${version}/sherlock-linux-x64";
      hash = "sha256-u/XyOTbwZXjTqidkAIhLOs51i/lVRlcHYCm+wv7Di+M=";
    };
  };

  system = prev.stdenv.hostPlatform.system;
  platformSrc = prebuiltSrcs.${system} or null;

  src = prev.fetchFromGitHub {
    owner = "michaelbromley";
    repo = "sherlock";
    rev = "v${version}";
    hash = "sha256-rY2jj1BZKvRWM56PaNeNe+0qgE4updDfWL1YXnq0/8g=";
  };

  skillMd = prev.writeText "SKILL.md" ''
    ---
    name: sherlock
    description: Allows read-only access to SQL databases for querying and analysis
    allowed-tools:
       - Bash(sherlock:*)
    ---

    # Sherlock

    Read-only database access for SQL. Binary: `sherlock` (in PATH)

    ## SQL Commands

    All SQL commands require `-c <connection>` or `-u <url>`. Output is JSON by default, use `-f markdown` for tables.

    ```bash
    sherlock connections                    # List available connections
    sherlock -c <conn> tables               # List tables
    sherlock -c <conn> describe <table>     # Table schema
    sherlock -c <conn> introspect           # Full schema (cached)
    sherlock -c <conn> introspect --refresh # Refresh cached schema
    sherlock -c <conn> query "SELECT ..."   # Execute read-only query
    sherlock -c <conn> sample <table> -n 10 # Random sample rows
    sherlock -c <conn> stats <table>        # Data profiling (nulls, distinct counts)
    sherlock -c <conn> indexes <table>      # Table indexes
    sherlock -c <conn> fk <table>           # Foreign key relationships
    ```

    ## The `org` Database

    The `org` connection provides read-only access to an Org-mode task database.

    Key tables: `entries`, `entry_tags`, `entry_stamps`, `entry_log_entries`,
    `entry_properties`, `entry_links`, `entry_embeddings`, `entry_body_blocks`,
    `entry_categories`, `entry_relationships`, `files`, `log_entry_body_blocks`

    **Timestamps are Modified Julian Day integers.** Convert with:
    `DATE '1858-11-17' + day` (e.g., today 2026-04-10 = MJD 61140)

    The `entries` table has a `tsv` column (tsvector) for full-text search.
    The `entry_embeddings` table has an `embedding` column (pgvector) for semantic search.

    ## Constraints

    - **Read-only**: Only SELECT, SHOW, DESCRIBE, EXPLAIN, WITH allowed
    - **Connection required**: Always specify `-c <connection>` or `-u <url>`
    - **Quoting**: PostgreSQL uses `"identifier"`

    ## Workflow

    1. Use `sherlock -c org introspect` to learn the schema
    2. Use `sherlock -c org sample <table> -n 5` to see real data
    3. Write SQL based on the user's question and schema
    4. Execute with `sherlock -c org query "SELECT ..." -f markdown`
    5. Always use LIMIT to avoid large result sets

    ## Tips

    - Use `-f markdown` for human-readable table output
    - Use `stats` for data profiling (row counts, null counts, distinct values)
    - Config: `~/.config/sherlock/config.json`
  '';

  # Pre-built binary package (aarch64-darwin, x86_64-linux)
  prebuiltPkg = prev.stdenv.mkDerivation {
    pname = "sherlock-db";
    inherit version;

    src = prev.fetchurl platformSrc;

    dontUnpack = true;

    nativeBuildInputs = prev.lib.optionals prev.stdenv.hostPlatform.isLinux [
      prev.autoPatchelfHook
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/share/sherlock
      cp $src $out/bin/sherlock
      chmod +x $out/bin/sherlock
      cp ${skillMd} $out/share/sherlock/SKILL.md
      runHook postInstall
    '';

    meta = with prev.lib; {
      description = "Read-only database query tool for AI assistants (PostgreSQL, MySQL, SQLite)";
      homepage = "https://github.com/michaelbromley/sherlock";
      license = licenses.mit;
      mainProgram = "sherlock";
      sourceProvenance = [ sourceTypes.binaryNativeCode ];
    };
  };

  # Fixed-output derivation: fetch node_modules via Bun using bun.lock
  # The upstream package-lock.json is stale (missing @clack/prompts),
  # so we use Bun's native package manager instead of npm.
  bunDeps = prev.stdenv.mkDerivation {
    pname = "sherlock-db-bun-deps";
    inherit version src;

    nativeBuildInputs = [
      prev.bun
      prev.cacert
    ];

    impureEnvVars = prev.lib.fetchers.proxyImpureEnvVars;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-YBE5CbNxgdbtS9YBXumAP7Gmq8JrNywLdsrAkBm/zpc=";

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      bun install --frozen-lockfile
      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out
      cp -r node_modules $out/node_modules
    '';

    dontFixup = true;
  };

  # Build from source package (aarch64-linux)
  # Uses Bun for both dependency resolution and compilation.
  # @napi-rs/keyring is excluded (--external) since there's no Secret Service
  # on headless Linux; passwords are read from config.json via LiteralProvider.
  fromSourcePkg = prev.stdenv.mkDerivation {
    pname = "sherlock-db";
    inherit version src;

    nativeBuildInputs = [ prev.bun ];

    # Bun --compile embeds the JS bundle at the end of the ELF binary.
    # Nix's default strip removes it, leaving just the bare Bun runtime.
    dontStrip = true;

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      cp -r ${bunDeps}/node_modules node_modules
      chmod -R u+w node_modules
      bun build ./src/query-db.ts \
        --compile \
        --external @napi-rs/keyring \
        --outfile sherlock
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/share/sherlock
      cp sherlock $out/bin/
      cp ${skillMd} $out/share/sherlock/SKILL.md
      runHook postInstall
    '';

    meta = with prev.lib; {
      description = "Read-only database query tool for AI assistants (PostgreSQL, MySQL, SQLite)";
      homepage = "https://github.com/michaelbromley/sherlock";
      license = licenses.mit;
      mainProgram = "sherlock";
      platforms = [ "aarch64-linux" ];
    };
  };

in
{
  sherlock-db =
    if platformSrc != null then
      prebuiltPkg
    else if system == "aarch64-linux" then
      fromSourcePkg
    else
      throw "sherlock-db: unsupported platform ${system}";
}
