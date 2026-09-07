# /etc/nixos/modules/services/model-config.nix
#
# Renders the shared Nix model policy at /etc/models.json for non-Nix consumers.
{ inputs, pkgs, ... }:

let
  models = (import "${inputs.nix-config}/config/ai/models.nix").nixos;
  modelsJson = pkgs.writeText "models.json" (builtins.toJSON models);
in
{
  environment.etc."models.json" = {
    source = modelsJson;
    mode = "0444";
  };
}
