{
  description = "gluck-matrix — Synapse homeserver + declarative Matrix users and bots on kelliher-web";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  # Thin wrapper: the NixOS module lives in ./modules (split by concern and
  # aggregated by ./modules/default.nix). Same shape as kelliher-web.
  outputs =
    { self, nixpkgs, ... }:
    {
      nixosModules.default = import ./modules;
    };
}
