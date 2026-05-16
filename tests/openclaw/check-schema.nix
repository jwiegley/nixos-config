# Standalone derivation that diffs the rendered openclaw-config-template's
# key set against the committed snapshot at expected-keys.txt.
# Imported from flake.nix as checks.<system>.openclaw-config-schema.
{
  pkgs,
  openclaw-config-template,
}:
pkgs.runCommand "openclaw-config-schema-check"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.diffutils
    ];
    expectedKeys = ./expected-keys.txt;
    template = openclaw-config-template;
  }
  ''
    set -euo pipefail
    actual=$(mktemp)
    trap 'rm -f "$actual"' EXIT

    jq -r 'paths | map(tostring) | join(".")' "$template" | sort > "$actual"

    if ! diff -u "$expectedKeys" "$actual"; then
      echo ""
      echo "openclaw-config-template's key set does not match the committed snapshot."
      echo ""
      echo "If this is a deliberate template change, regenerate the snapshot:"
      echo ""
      echo "  TPL=\$(nix build --no-link --print-out-paths '/etc/nixos#nixosConfigurations.vulcan.pkgs.openclaw-config-template')"
      echo "  jq -r 'paths | map(tostring) | join(\".\")' \"\$TPL\" | sort > tests/openclaw/expected-keys.txt"
      echo "  git add tests/openclaw/expected-keys.txt"
      echo ""
      echo "Then commit with a message describing why."
      exit 1
    fi

    touch "$out"
  ''
