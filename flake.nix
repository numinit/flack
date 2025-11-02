{

  description = "Serve your flakes";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-lib.url = "github:numinit/nixpkgs.lib";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    flakever.url = "github:numinit/flakever";
    nix-cargo-integration.url = "github:90-008/nix-cargo-integration";
    nix-bindings-rust.url = "github:numinit/nix-bindings-rust";
  };

  outputs =
    inputs@{
      self,
      nixpkgs-lib,
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
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.nix-cargo-integration.flakeModule
        inputs.nix-bindings-rust.modules.flake.default
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      flake = rec {
        versionTemplate = "0.1-<lastModifiedDate>-<rev>";
        inherit (flakeverConfig) version versionCode;

        lib = import ./lib.nix {
          inherit (nixpkgs-lib) lib;
        };

        flack.app = lib.mkApp {
          mount = {
            "/pkgs" = {
              route.GET."/:...path" =
                req:
                let
                  pkgs = self.legacyPackages.${req.system};
                  inherit (pkgs) lib;
                  pkg = lib.attrByPath req.params.path null pkgs;
                  subPath =
                    let
                      names = lib.attrNames req.query;
                    in
                    if lib.length names == 1 then lib.strings.normalizePath ("/" + lib.head names) else "";
                in
                if pkg == null then req.res 400 else req.res 200 { } "${pkg}${subPath}";
            };
          };
          use = {
            "/foo" =
              req: if req.get "X-Auth-Token" != "supersecret" then req.res 401 { } "Unauthorized" else req;
          };
          route = {
            GET."/" = req: req.res 200 { "hello" = "world"; };
            GET."/foo/:bar" =
              req:
              req.res 200 { } {
                inherit (req) pathComponents;
                inherit (req.params) bar;
              };
            POST."/foo/:bar" = req: req.res 201 { inherit (req.params) bar; };
            GET."/baz" = req: req.res 200 { "baz" = "quux"; };
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
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
            ];
            config = {
              allowUnfree = true;
            };
          };

          nix-bindings-rust.nixPackage = pkgs.nixVersions.latest;

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

          legacyPackages = pkgs;

          packages = {
            default = pkgs.flack;
            inherit (pkgs) flack;
          };

          devShells = {
            default = outputs."flack".devShell;
          };
        };
    };
}
