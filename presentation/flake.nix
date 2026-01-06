{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-lib.url = "github:numinit/nixpkgs.lib";
    htnl.url = "github:molybdenumsoftware/htnl";
    flack = {
      url = ./..;
      inputs.flack-lib.follows = "flack-lib";
    };
    flack-lib.url = ./../lib;
  };

  outputs =
    {
      self,
      nixpkgs-lib,
      ...
    }@inputs:
    let
      inherit (nixpkgs-lib) lib;
      inherit (inputs.flack-lib) flack;
    in
    {
      flack.apps.default = flack.mkApp {
        modules = [ ./apps ];
        specialArgs = {
          inherit self inputs;
        };
      };

      packages = {
        # This is the closure of all the app dependencies.
        x86_64-linux.flack-closure-presentation = self.flack.apps.default.mkClosure rec {
          system = "x86_64-linux";
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          inherit self;
          flack = inputs.flack;
        };
      };

      inherit (inputs.flack) apps;
    };
}
