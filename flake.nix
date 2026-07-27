{
  description = "kmatrix — Synapse homeserver + declarative Matrix users and bots on kelliher-web";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  # The NixOS module lives in ./modules (split by concern and aggregated
  # by ./modules/default.nix). ./bots holds reference bots, packaged so a
  # host config can wire one up with `lib.getExe`.
  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules.default = import ./modules;

      overlays.default = final: _prev: {
        kmatrix-echo = final.callPackage ./bots/echo/package.nix { };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          kmatrix-echo = pkgs.callPackage ./bots/echo/package.nix { };
          default = kmatrix-echo;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              go
              gopls
              gotools
            ];
          };
        }
      );
    };
}
