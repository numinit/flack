{ lib, pkgs, ... }:

let
  /*
    Recursively find all packages (derivations) in `pkgs` matching `cond` predicate.

    Type: packagesUnder :: AttrPath → (AttrPath → derivation → bool) → AttrSet → AttrSet → List<AttrSet{name :: str; value :: derivation; extra :: AttrSet}>
          AttrPath :: [str]

    The packages will be returned as a list of named pairs comprising of:
      - name: stringified attribute path (based on `rootPath`)
      - package: corresponding derivation

    Adapted from: <nixpkgs>/maintainers/scripts/update.nix
    License: MIT
  */
  packagesUnder =
    rootPath: cond: extra: pkgs:
    let
      packagesWithPathInner =
        path: pathContent:
        let
          result = builtins.tryEval pathContent;
        in
        if result.success then
          let
            evaluatedPathContent = result.value;
          in
          if lib.isDerivation evaluatedPathContent then
            lib.optional (cond path evaluatedPathContent) {
              name = lib.concatStringsSep "." path;
              value = evaluatedPathContent;
              inherit extra;
            }
          else if lib.isAttrs evaluatedPathContent then
            # If user explicitly points to an attrSet or it is marked for recursion, we recur.
            if
              path == rootPath
              || evaluatedPathContent.recurseForDerivations or false
              || evaluatedPathContent.recurseForRelease or false
            then
              lib.concatLists (
                lib.mapAttrsToList (name: elem: packagesWithPathInner (path ++ [ name ]) elem) evaluatedPathContent
              )
            else
              [ ]
          else
            [ ]
        else
          [ ];
    in
    packagesWithPathInner rootPath pkgs;

  /*
    Reads NixOS options.

    nixpkgs: a nixpkgs instance
    extra: extra info to attach to each option
    module: the module to read
    modulePath: the path of the module, e.g. [ "github:foo/bar" "default" ];

    Adapted from: https://github.com/NixOS/nixos-search/blob/f31c2a395ecb3be05aba82bdb8f224d42d280f29/flake-info/assets/commands/flake_info.nix
  */
  readNixOSOptions =
    let
      declarations =
        nixpkgs: module:
        (lib.evalModules {
          modules = (if lib.isList module then module else [ module ]) ++ [
            (
              { ... }:
              {
                _module.check = false;
              }
            )
          ];
          specialArgs = {
            # !!! NixOS-specific. Unfortunately, NixOS modules can rely on the `modulesPath`
            # argument to import modules from the nixos tree. However, most of the time
            # this is done to import *profiles* which do not declare any options, so we
            # can allow it.
            inherit pkgs;
            modulesPath = "${nixpkgs.path}/nixos/modules";
          };
        }).options;

      cleanUpOption =
        extraAttrs: opt:
        let
          applyOnAttr = n: f: lib.optionalAttrs (builtins.hasAttr n opt) { ${n} = f opt.${n}; };
          mkDeclaration =
            decl:
            let
              discard = lib.concatStringsSep "/" (lib.take 4 (lib.splitString "/" decl)) + "/";
              path = if lib.hasPrefix builtins.storeDir decl then lib.removePrefix discard decl else decl;
            in
            path;

          # Replace functions by the string <function>
          substFunction =
            x:
            if !(builtins.tryEval x).success then
              "eval error"
            else if builtins.isAttrs x then
              lib.mapAttrs (_: substFunction) x
            else if builtins.isList x then
              map substFunction x
            else if lib.isFunction x then
              "function"
            else
              x;
        in
        {
          inherit (opt) name;
          value =
            opt
            // {
              entry_type = "option";
            }
            // applyOnAttr "default" substFunction
            // applyOnAttr "example" substFunction # (_: { __type = "function"; })
            // applyOnAttr "type" substFunction
            // applyOnAttr "declarations" (map mkDeclaration)
            // extraAttrs;
        };
    in
    {
      nixpkgs,
      extra ? { },
      module,
      modulePath ? null,
    }:
    let
      opts = lib.optionAttrSetToDocList (declarations nixpkgs module);
      extraAttrs =
        lib.optionalAttrs (modulePath != null) {
          inherit modulePath;
        }
        // {
          inherit extra;
        };
    in
    map (cleanUpOption extraAttrs) (
      lib.filter (x: x.visible && !x.internal && lib.head x.loc != "_module") opts
    );

  # Gets options under the specified flake.
  flakeOptionsUnder =
    {
      nixpkgs,
      flake,
      resolved,
      extra ? { },
    }:
    let
      nixosModulesOpts = lib.concatLists (
        lib.mapAttrsToList (
          moduleName: module:
          readNixOSOptions {
            inherit nixpkgs extra module;
            modulePath =
              lib.optionals (flake ? url) [
                flake.url
              ]
              ++ [
                moduleName
              ];
          }
        ) (resolved.nixosModules or { })
      );

      nixosModuleOpts = lib.optionals (resolved ? nixosModule) (readNixOSOptions {
        inherit nixpkgs extra;
        module = resolved.nixosModule;
        modulePath = lib.optional (flake ? url) flake.url;
      });
    in
    # We assume that `nixosModules` includes `nixosModule` when there
    # are multiple modules
    if nixosModulesOpts != [ ] then nixosModulesOpts else nixosModuleOpts;

  # Gets NixOS options under the specified `nixpkgs`.
  nixosOptionsUnder =
    { nixpkgs, extra }:
    readNixOSOptions {
      inherit nixpkgs extra;
      module = import "${nixpkgs}/nixos/modules/module-list.nix" ++ [
        "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
        { nixpkgs.hostPlatform = "x86_64-linux"; }
      ];
    };
in
{
  inherit packagesUnder flakeOptionsUnder nixosOptionsUnder;
}
