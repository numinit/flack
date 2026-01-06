{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flack = {
      url = "./..";
      inputs.flack-lib.follows = "flack-lib";
    };
    flack-lib.url = "./../lib";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      flack,
      flack-lib,
      nixpkgs,
      ...
    }:
    let
      inherit (inputs) nixpkgs;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      flake =
        let
          inherit (flack-lib) flack;
        in
        {
          flack.apps.default = flack.mkApp {
            modules = [ ./apps ];
            specialArgs = {
              inherit self inputs;
            };
          };
          /*
            nixosConfigurations.default =
            nixpkgs.lib.nixosSystem {
              modules = [
                ./systems/netboot.nix
              ];
              specialArgs = {
                inherit self inputs;
              };
            };
          */

          overlays.default = (
            final: prev: {
              flack-closure-netboot = self.flack.apps.default.mkClosure {
                inherit (final.stdenv.hostPlatform) system;
                pkgs = final;

                # Have to do this manually because it's an infinite recursion if we don't...
                forceApp = false;
                includeFlackInDependencies = true;
                inherit self;
                inherit (inputs) flack;
              };
            }
          );

          inherit (inputs.flack) apps;
        };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          config,
          system,
          pkgs,
          final,
          lib,
          ...
        }:
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            overlays = [
              flack.overlays.default
              self.overlays.default
            ];
            config = { };
          };

          packages = {
            # This is the closure of all the app dependencies.
            inherit (pkgs) flack-closure-netboot;
          };

          checks = {
            netbootTest = pkgs.callPackage ./nixos/tests/netboot.nix {
              inherit inputs self;
            };
          };
        };
    };
}
