# /etc/nixos/modules/services/model-config.nix
#
# Deploys a JSON serialization of models.nix to /etc/models.json
# for non-Nix consumers (Python scripts).
{ pkgs, ... }:

let
  models = import ../../models.nix;
  modelsJson = pkgs.writeText "models.json" (builtins.toJSON models);
in
{
  environment.etc."models.json" = {
    source = modelsJson;
    mode = "0444";
  };
}
