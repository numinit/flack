{
  description = "Serve your flakes";
  inputs = {
    nix.url = "github:numinit/nix/flack";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-lib.url = "github:numinit/nixpkgs.lib";
    flack-lib.url = ./lib;
    flake-parts.url = "github:hercules-ci/flake-parts";
    flakever.url = "github:numinit/flakever";
    nix-cargo-integration.url = "github:90-008/nix-cargo-integration";
    nix-bindings-rust.url = ./rust/nix-bindings-rust;
    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nix,
      nixpkgs-lib,
      flack-lib,
      flake-parts,
      flakever,
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
      inherit (flack-lib) flack;
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

        flack = {
          apps.default = flack.mkApp {
            modules = [ ./apps ];
            specialArgs = {
              inherit inputs;
            };
          };

          apps.simple = flack.mkApp {
            route = {
              GET."/" = req: req.res 200 "Hello, Flack!\n";
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
          };

          packages = rec {
            default = flack;
            flack = outputs."flack".packages.release;
            flack-closure-default = self.flack.apps.default.mkClosure {
              inherit system;
              pkgs = final;
              inherit self;
              flack = self;
            };
            flack-closure-simple = self.flack.apps.simple.mkClosure {
              inherit system;
              pkgs = final;
              inherit self;
              flack = self;
            };
          };

          legacyPackages.flack = packages.flack;

          apps.default = {
            program = "${pkgs.flack}/bin/flack-serve";
          };

          devShells = {
            default = outputs."flack".devShell.overrideAttrs (prev: {
              buildInputs = prev.buildInputs or [ ] ++ [
                pkgs.gdb
                nix.packages.${system}.default
              ];
            });
          };
        };
    };
}
