{
  description = "The Flack web router";
  inputs = {
    nixpkgs-lib.url = "github:numinit/nixpkgs.lib";
  };

  outputs =
    inputs@{
      self,
      nixpkgs-lib,
      ...
    }:
    let
      inherit (nixpkgs-lib) lib;
    in
    {
      flack = import ./flack.nix {
        inherit self lib inputs;
      };

      nixosModules.default = import ./nixos-module.nix;
    };
}
