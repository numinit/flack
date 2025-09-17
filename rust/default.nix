{
  lib,
  pkgs,
  crane,
  nixVersions,
  pkg-config,
}:

let
  craneLib = crane.mkLib pkgs;
  cargoToml = lib.importTOML ./Cargo.toml;
  version = cargoToml.workspace.package.version;
  src = ./.;

  commonArgs = {
    pname = "flack";
    inherit src version;
    strictDeps = true;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (commonArgs // {
  inherit cargoArtifacts;

  LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
  RUSTC_BOOTSTRAP = 1;

  nativeBuildInputs = [ pkg-config ];

  buildInputs = [
    nixVersions.nixComponents_2_31.nix-flake-c
  ];

  doCheck = false;

  preConfigure = ''
    source ${./bindgen-gcc.sh}
  '';
})
