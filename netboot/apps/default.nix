{
  lib,
  pkgs,
  flack,
  self,
  inputs,
  ...
}:

let
  inherit (inputs) nixpkgs;

  inherit (lib.versions) majorMinor;

  inherit (flack.lib.paths) joinPathToIndex;

  inherit (flack.lib.log) mkLog;

  name = "flack-netboot";

  Log = mkLog name;

  nixosSystem =
    let
      system = "x86_64-linux";
    in
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        (
          { modulesPath, ... }:
          {
            imports = [
              "${modulesPath}/installer/netboot/netboot-minimal.nix"

              # TODO: ONLY FOR TESTING!
              "${modulesPath}/testing/test-instrumentation.nix"
            ];

            nixpkgs.overlays = [
              self.overlays.default
            ];
          }
        )
        inputs.flack-lib.nixosModules.default

        ../systems/netboot.nix
        ../systems/netboot/flack.nix
      ];
      specialArgs = {
        inherit self inputs;
      };
    };
in
{
  inherit name;

  route =
    let
      mkNetboot =
        req: nixosSystem:
        let
          pkgs = nixpkgs.legacyPackages.${req.system};
          hostname = nixosSystem.config.networking.hostName;
        in
        pkgs.symlinkJoin {
          name = "nixos-system-${hostname}-netboot";
          paths = with nixosSystem.config.system.build; [
            netbootRamdisk
            kernel
            netbootIpxeScript
          ];
        };
    in
    {
      GET."/:...path" =
        req:
        let
          netboot = mkNetboot req nixosSystem;
        in
        req.res 200 { } "${netboot}${joinPathToIndex req.params.path}" {
          inherit netboot;
        };
    };
}
