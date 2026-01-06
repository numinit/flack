{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-legacy.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-lib.url = "github:numinit/nixpkgs.lib";
    nixos-search.url = "github:NixOS/nixos-search";
    flack = {
      url = ./..;
      inputs.flack-lib.follows = "flack-lib";
    };
    flack-lib.url = ./../lib;

    # This one gets overridden to the search target.
    flake = {
      url = "github:numinit/flack?dir=search";
    };
  };

  outputs =
    {
      self,
      nixpkgs-lib,
      nixos-search,
      ...
    }@inputs:
    let
      inherit (nixpkgs-lib) lib;
      inherit (inputs.flack-lib) flack;

      # We don't have access to self in inputs, so add it here.
      self' = self // {
        url = "file:.";
      };

      # "Inputs prime" is inputs updated with the URLs and self, minus the lib.
      inputs' = builtins.removeAttrs (lib.recursiveUpdate (import ./flake.nix).inputs (
        inputs
        // {
          self = self';
        }
      )) [ "flack-lib" ];
    in
    {
      flack.apps.default = flack.mkApp {
        modules = [ ./apps ];
        specialArgs = {
          inherit self' inputs';
        };
      };

      packages = {
        # This is the closure of all the app dependencies.
        x86_64-linux.flack-closure-search = self'.flack.apps.default.mkClosure rec {
          system = "x86_64-linux";
          pkgs = inputs'.nixpkgs.legacyPackages.${system};
          self = self';
          flack = inputs'.flack;
        };
      };

      inherit (inputs.flack) apps;
    };
}
