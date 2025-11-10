{
  description = "Serve your flakes";
  inputs = {
    nix.url = "github:DeterminateSystems/nix-src";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-lib.url = "github:numinit/nixpkgs.lib";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    flakever.url = "github:numinit/flakever";
    nix-cargo-integration.url = "github:90-008/nix-cargo-integration";
    nix-bindings-rust.url = "github:numinit/nix-bindings-rust";

    nixos-search.url = "github:NixOS/nixos-search";
  };

  outputs =
    inputs@{
      self,
      nix,
      nixpkgs-lib,
      flake-parts,
      flakever,
      nixos-search,
      ...
    }:
    let
      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [
          1
          2
          2
        ];
      };
      inherit (nixpkgs-lib) lib;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.nix-cargo-integration.flakeModule
        inputs.nix-bindings-rust.modules.flake.default
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      flake = {
        versionTemplate = "0.2-<lastModifiedDate>-<rev>";
        inherit (flakeverConfig) version versionCode;

        flack =
          let
            flack = import ./flack.nix lib;
          in
          flack
          // {
            apps.simple = flack.mkApp {
              route = {
                GET."/" = req: req.res 200 "Hello, Flack!";
              };
            };

            apps.default = flack.mkApp {
              modules = [ ./apps ];
              specialArgs = rec {
                inherit self inputs;

                # We don't have access to self in inputs, so add it here.
                self' = self // {
                  url = "file:.";
                };

                # "Inputs prime" is inputs updated with the URLs and self.
                inputs' = lib.recursiveUpdate (import ./flake.nix).inputs (inputs // { self = self'; });
              };
            };
          };
      };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          config,
          system,
          inputs',
          pkgs,
          final,
          ...
        }:
        let
          outputs = config.nci.outputs;
        in
        rec {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
            ];
            config = {
              allowUnfree = true;
            };
          };

          nix-bindings-rust.nixPackage = nix.packages.${system}.default;

          nci.projects."flack" = rec {
            path = ./rust;
            export = true;
            depsDrvConfig = {
              imports = [ config.nix-bindings-rust.nciBuildConfig ];
              env.RUSTC_BOOTSTRAP = 1;
            };
            drvConfig = depsDrvConfig;
          };

          overlayAttrs = {
            flack = outputs."flack".packages.release;
            nixos-search-frontend = nixos-search.packages.${system}.frontend;
          };

          packages = rec {
            flack = outputs."flack".packages.release;
            default = flack;
          };

          legacyPackages.flack = packages.flack;

          apps.default = {
            program = "${pkgs.flack}/bin/flack-serve";
          };

          devShells = {
            default = outputs."flack".devShell.overrideAttrs (prev: {
              buildInputs = prev.buildInputs or [ ] ++ [ pkgs.gdb ];
            });
          };
        };
    };
}
