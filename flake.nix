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

      # The protocol test must run as root: the shipped provisioner does
      # install -d -o root -g root before anything else, and the nix sandbox
      # has no root. So it is a package you run on the host, over the same
      # ExecStart systemd runs, rather than a hermetic check.
      e2eFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = nixpkgs.lib;
          rig =
            (lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  options.services.kelliher-web = {
                    baseDomains = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ "test" ];
                    };
                    sites = lib.mkOption {
                      type = lib.types.attrsOf lib.types.anything;
                      default = { };
                    };
                  };
                }
                {
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "none";
                    fsType = "tmpfs";
                  };
                  system.stateVersion = "25.05";
                  services.kmatrix = {
                    enable = true;
                    serverName = "test";
                    stateDir = "/tmp/kmatrix-e2e/state";
                    port = 18831;
                    bots.echo = {
                      displayName = "Echo Bot";
                      autoJoin = [ "#general:test" ];
                    };
                  };
                }
              ];
            }).config;
        in
        pkgs.writeShellApplication {
          name = "kmatrix-e2e";
          runtimeInputs = with pkgs; [
            bash
            curl
            jq
            coreutils
            gnugrep
            strace
            python3
          ];
          text = ''
            exec ${pkgs.bash}/bin/bash ${./tests/e2e.sh} \
              ${rig.systemd.services."kmatrix-account-echo".serviceConfig.ExecStart} \
              ${pkgs.python3}/bin/python3 \
              ${./tests} \
              /tmp/kmatrix-e2e/state
          '';
        };

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
          e2e = e2eFor system;
          default = kmatrix-echo;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = nixpkgs.lib;

          rig =
            (lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  options.services.kelliher-web = {
                    baseDomains = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ "test" ];
                    };
                    sites = lib.mkOption {
                      type = lib.types.attrsOf lib.types.anything;
                      default = { };
                    };
                  };
                }
                {
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "none";
                    fsType = "tmpfs";
                  };
                  system.stateVersion = "25.05";
                  services.kmatrix = {
                    enable = true;
                    serverName = "test";
                    stateDir = "/tmp/kmatrix-e2e/state";
                    port = 18831;
                    bots.echo = {
                      displayName = "Echo Bot";
                      autoJoin = [ "#general:test" ];
                    };
                  };
                }
              ];
            }).config;

          provision = rig.systemd.services."kmatrix-account-echo".serviceConfig.ExecStart;
          adminPkg = lib.findFirst (
            d: (d.pname or d.name or "") == "kmatrix-admin"
          ) null rig.environment.systemPackages;
          admin = "${adminPkg}/bin/kmatrix-admin";

          testPy = pkgs.python3;
        in
        {
          argv = pkgs.runCommand "kmatrix-argv-scan" { } ''
            set -o pipefail
            ${pkgs.bash}/bin/bash ${./tests/argv.sh} ${provision} ${admin} 2>&1 | tee $out
          '';

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
