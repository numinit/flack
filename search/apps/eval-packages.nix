{
  lib,
  flack,
  pkgs,
  ...
}:

let
  inherit (builtins)
    storeDir
    ;

  inherit (lib.trivial) isFunction;

  inherit (lib.strings)
    concatStringsSep
    splitString
    hasPrefix
    removePrefix
    ;

  inherit (lib.lists)
    isList
    length
    elemAt
    optional
    optionals
    concatLists
    head
    take
    filter
    ;

  inherit (lib.attrsets)
    isAttrs
    isDerivation
    hasAttr
    attrsToList
    mapAttrs
    mapAttrsToList
    optionalAttrs
    ;

  inherit (lib.modules)
    evalModules
    ;

  inherit (lib.options)
    optionAttrSetToDocList
    ;

  inherit (flack.lib.trivial) tryOrNull tryOrNull';

  inherit (flack.lib.lists) parallel;

  # Returns whether this path refers to a Flack closure (so eval would cause infinite recursion).
  # Note that we also rule out tests since (at least on 25.05 through 26.05)
  # they re-import nixpkgs without system set, which breaks in impure mode.
  isFlackReservedPath =
    path:
    let
      last = (elemAt path (length path - 1));
    in
    length path > 0 && (hasPrefix "flack-closure-" last || last == "tests");

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
          result = tryOrNull' pathContent;
        in
        if !(isFlackReservedPath path) && result.success then
          let
            evaluatedPathContent = result.value;
          in
          if isDerivation evaluatedPathContent then
            optional (cond path evaluatedPathContent) {
              name = concatStringsSep "." path;
              value = evaluatedPathContent;
              inherit extra;
            }
          else if isAttrs evaluatedPathContent then
            # If user explicitly points to an attrSet or it is marked for recursion, we recur.
            if
              path == rootPath
              || evaluatedPathContent.recurseForDerivations or false
              || evaluatedPathContent.recurseForRelease or false
            then
              let
                pathLists = mapAttrsToList (
                  name: elem: packagesWithPathInner (path ++ [ name ]) elem
                ) evaluatedPathContent;
              in
              concatLists (parallel pathLists pathLists)
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
        (evalModules {
          modules = (if isList module then module else [ module ]) ++ [
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
            modulesPath = "${nixpkgs}/nixos/modules";
          };
        }).options;

      cleanUpOption =
        extraAttrs: opt:
        let
          applyOnAttr = n: f: optionalAttrs (hasAttr n opt) { ${n} = f opt.${n}; };
          mkDeclaration =
            decl:
            let
              discard = concatStringsSep "/" (take 4 (splitString "/" decl)) + "/";
              path = if hasPrefix storeDir decl then removePrefix discard decl else decl;
            in
            path;

          # Replace functions by the string <function>
          substFunction =
            x:
            let
              x' = tryOrNull x;
            in
            if x' == null then
              "eval error"
            else if isAttrs x' then
              mapAttrs (_: substFunction) x'
            else if isList x' then
              map substFunction x'
            else if isFunction x' then
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
      opts = optionAttrSetToDocList (declarations nixpkgs module);
      extraAttrs =
        optionalAttrs (modulePath != null) {
          inherit modulePath;
        }
        // {
          inherit extra;
        };
      filtered = parallel opts (filter (x: x.visible && !x.internal && head x.loc != "_module") opts);
      cleaned = parallel filtered (map (cleanUpOption extraAttrs) filtered);
    in
    cleaned;

  # Gets options under the specified flake.
  flakeOptionsUnder =
    {
      nixpkgs,
      name,
      flake,
      resolved,
      extra ? { },
      urlOverride ? name: url: url,
    }:
    let
      nixosModulesOpts = concatLists (
        mapAttrsToList (
          moduleName: module:
          readNixOSOptions {
            inherit nixpkgs extra module;
            modulePath =
              optionals (flake ? url) [
                (urlOverride name flake.url)
              ]
              ++ [
                moduleName
              ];
          }
        ) (resolved.nixosModules or { })
      );

      nixosModuleOpts = optionals (resolved ? nixosModule) (readNixOSOptions {
        inherit nixpkgs extra;
        module = resolved.nixosModule;
        modulePath = optional (flake ? url) (urlOverride name flake.url);
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
  inherit
    packagesUnder
    flakeOptionsUnder
    nixosOptionsUnder
    isFlackReservedPath
    ;
}
