# Compatibility adapter for Nix modules.  models.yaml is written as JSON,
# which is a strict YAML subset that Nix can parse without import-from-
# derivation or a second generated copy.
builtins.fromJSON (builtins.readFile ./models.yaml)
