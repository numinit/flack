{
  description = "Serve your flakes";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    flakever.url = "github:numinit/flakever";
    crane.url = "github:ipetkov/crane";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      flakever,
      ...
    }:
    let
      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [ 1 2 2 ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      flake = rec {
        versionTemplate = "0.1-<lastModifiedDate>-<rev>";
        inherit (flakeverConfig) version versionCode;
        flack.app = { ... }@env:
        let
          pkgs = self.legacyPackages.${env."flack.system"};
          inherit (pkgs) lib;
          route = lib.filter (x: x != "") (lib.splitString "/" (env.PATH_INFO or "/"));

          action = if lib.length route > 0 then lib.lists.head route else null;
          path = lib.lists.drop 1 route;

          headers = {
            "Server" = "Flack ${version}";
          };
        in
        if action == null then
          [ 200 headers env ]
        else if action == "pkgs" then
          let
            subPath = let
              match = lib.match "^([^=&]+)$" (env.QUERY_STRING or "");
            in if match == null then "" else "/${lib.strings.removePrefix "/" (lib.lists.head match)}";
            pkg = lib.attrByPath path null pkgs;
          in
          if pkg == null then
            [ 404 headers rec {attrPath = lib.concatStringsSep "." path; error = "Package ${attrPath} didn't exist"; } ]
          else
            [ 200 headers "${pkg}${subPath}" ]
        else if action == "cgi-bin" then
          let
            result = pkgs.runCommandNoCCLocal "date" env ''
              date > $out
            '';
          in
          [ 200 headers result ]
        else
          [ 404 headers "Not found" ];
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
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
            ];
            config = { allowUnfree = true; };
          };

          overlayAttrs = {
            flack = pkgs.callPackage ./rust {
              crane = inputs.crane;
            };
          };

          legacyPackages = pkgs;

          packages =
          {
            default = pkgs.flack;
            inherit (pkgs) flack;
          };

          devShells = {
            default = pkgs.flack.overrideAttrs (prevAttrs: {
              nativeBuildInputs = with pkgs; prevAttrs.nativeBuildInputs ++ [
                cargo-watch
                rust-analyzer
                rustfmt
                clippy
              ];

              shellHook = ''
                runPhase configurePhase
              '';
            });
          };
        };
    };
}
