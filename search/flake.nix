{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-lib.url = "github:numinit/nixpkgs.lib";
    nixos-search.url = "github:NixOS/nixos-search";
    flack.url = ./..;

    # This one gets overridden to the search target.
    flake.url = "github:numinit/flack?dir=search";
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
      inherit (inputs.flack) flack;
    in
    {
      flack.apps.default = flack.mkApp {
        modules = [ ./apps ];
        specialArgs = rec {
          inherit self inputs;

          # We don't have access to self in inputs, so add it here.
          self' = self // {
            url = "file:.";
          };

          # "Inputs prime" is inputs updated with the URLs and self.
          inputs' = lib.recursiveUpdate (import ./flake.nix).inputs (
            inputs
            // {
              self = self';
            }
          );
        };
      };

      inherit (inputs.flack) apps;
    };
}
