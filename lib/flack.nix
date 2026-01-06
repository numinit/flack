{
  self,
  # Alternate name so we don't shadow `self` in other contexts,
  # if we need to refer to flack-lib.
  self' ? self,

  inputs,
  lib,
}:

let
  inherit (lib.modules) evalModules;

  inherit (lib.strings)
    typeOf
    isStringLike
    concatMapStringsSep
    escapeShellArgs
    escapeShellArg
    toJSON
    ;

  inherit (lib.lists)
    isList
    length
    optional
    optionals
    singleton
    filter
    concatMap
    elemAt
    foldl
    flatten
    toposort
    sublist
    genList
    ;

  inherit (lib.attrsets)
    isAttrs
    hasAttr
    optionalAttrs
    attrValues
    foldlAttrs
    mapAttrs
    mapAttrsToList
    updateManyAttrsByPath
    ;

  inherit (lib.trivial) isFunction deepSeq;

  flackLib = import ./lib.nix {
    inherit self lib inputs;
  };

  inherit (flackLib.trivial)
    isFunctor
    isFlakeInput
    nullable
    tryOr
    tryOrNull
    tryOr'
    ;
  inherit (flackLib.strings) isReserved;
  inherit (flackLib.lists) parallel;
  inherit (flackLib.paths) splitPath joinPath pathPlaceholder;
  inherit (flackLib.log) mkLog;
  inherit (flackLib.flack)
    mkReq
    mkPureEnv
    mkClosure
    getInputsRecursive
    ;

  Log = mkLog "flack";

  # Executes the given middleware. Supports a list of functions or function-like objects.
  # Each middleware returns a request or a response. If it's a response, this is a no-op.
  execMiddleware =
    req: fnOrList:
    if fnOrList == null || isAttrs req && req.type == "res" then
      # Terminal state or nothing to do.
      req
    else if isAttrs req && req.type == "req" then
      if isFunction fnOrList || isFunctor fnOrList then
        fnOrList req
      else if isList fnOrList then
        foldl execMiddleware req fnOrList
      else
        req
    else
      throw "Request or response had invalid type";

  # Creates a middleware by delegating to the previous middleware.
  mkMiddleware =
    prev: next:
    (if prev == null then { } else prev)
    // next
    // {
      __functor =
        self: req:
        if prev == null then
          execMiddleware req next
        else
          let
            prevResult = execMiddleware req prev;
          in
          execMiddleware prevResult next;
    };

  # Transforms the given path (e.g. "/foo/:bar/baz") into a list where
  # parameters are replaced with the empty string, e.g.
  # [ { param = "foo"; splat = false; path = [ "/" "foo" "%" ]; __functor = (resolves this node); }
  #   { param = null; splat = true; path = [ "/" "foo" "%" "baz" ]; __functor = (resolves the terminal node) } ]
  # Note that the rest of the parameters can be indicated with `:...var`, e.g. "/foo/:...bars".
  # Anything after a `:...` splat param is ignored.
  # All of these paths can be passed safely into updateManyAttrsByPath.
  mkRouters =
    prefix: path: handler:
    let
      pathComponents = splitPath prefix path;
      inherit (flackLib.paths) matchRoutePlaceholder;
    in
    foldl (
      s: x:
      let
        isSplat = length s > 0 && (elemAt s (length s - 1)).splat';
        isLast = length x == length pathComponents;
        componentMatch = matchRoutePlaceholder (elemAt x (length x - 1));
        mkPath = map (val: if matchRoutePlaceholder val == null then val else pathPlaceholder);
        thePath =
          if isSplat || componentMatch == null && !isLast then
            # We already have the last path component, or this is a normal path component.
            null
          else if componentMatch != null then
            let
              willBeLast = elemAt componentMatch 0 == "...";
            in
            # Path placeholder.
            {
              type' = "middleware";
              param' = elemAt componentMatch 1;
              splat' = willBeLast;
              path' = mkPath x;
              __functor =
                self: req:
                let
                  pathIdx = length self.path' - 1;
                in
                if self.param' != null && (elemAt self.path' pathIdx) == pathPlaceholder then
                  # We need to parse a param.
                  let
                    req' = req // {
                      params = req.params // {
                        ${self.param'} =
                          if self.splat' then
                            # Rest of the URL should be splatted.
                            sublist pathIdx (length req.pathComponents - pathIdx) req.pathComponents
                          else
                            # Substitute just the parameter.
                            elemAt req.pathComponents pathIdx;
                      };
                    };
                  in
                  handler req'
                else
                  handler req;
            }
          else if isLast then
            # Terminal component.
            {
              type' = "middleware";
              param' = null;
              splat' = false;
              path' = mkPath x;
              __functor = _: handler;
            }
          else
            # Nothing.
            null;
      in
      if thePath == null then
        # Not a match, or the final element eats the rest of the path.
        s
      else
        s ++ singleton thePath
    ) [ ] (genList (x: sublist 0 (x + 1) pathComponents) (length pathComponents));

  # Makes a series of attribute updates for a router.
  mkRouterUpdates =
    method: prefix: pathFns:
    let
      routers = flatten (mapAttrsToList (mkRouters prefix) pathFns);
      sortedRouters = toposort (prefix: val: lib.lists.hasPrefix prefix.path' val.path') routers;
    in
    # Creates the list of updates.
    map (router: {
      inherit method;
      path = router.path';
      update = val: mkMiddleware (tryOrNull val) router;
    }) sortedRouters.result;

  # Makes a series of attribute updates for an app.
  mkAppUpdates =
    prefix:
    {
      mount ? { },
      use ? { },
      route ? { },
    }:
    let
      mounts = foldlAttrs (
        s: name: value:
        s ++ mkAppUpdates name value
      ) [ ] mount;
      uses = mkRouterUpdates null prefix use;

      # We need to transform GET."/foo/bar" = ..., POST."/foo/bar" = ...
      # into a single "/foo/bar" = (delegate handlers for each method).
      annotateRoutes =
        method:
        mapAttrs (
          path: routeFn: req:
          let
            numReqComponents = length req.pathComponents;
            numPathComponents = length (splitPath prefix path);
            isSplat = req.app ? splat' && req.app.splat' == true;
          in
          if
            req.method == method
            && (
              isSplat && numReqComponents >= numPathComponents
              || !isSplat && numReqComponents == numPathComponents
            )
          then
            execMiddleware req routeFn
          else
            # Next middleware
            req
        );
      flattenedRoutes = foldlAttrs (
        s: method: routeFns:
        s ++ mkRouterUpdates method prefix (annotateRoutes method routeFns)
      ) [ ] route;
    in
    mounts ++ uses ++ flattenedRoutes;

  mkApp' =
    {
      name,
      mount ? { },
      use ? { },
      route ? { },
      devDependencies ? [ ],
    }@args:
    let
      updates = mkAppUpdates "/" (
        removeAttrs args [
          "name"
          "devDependencies"
        ]
      );

      app = updateManyAttrsByPath updates {
        # Creates the closure of this webapp and the given extra paths.
        mkClosure =
          {
            system,
            self ? null,
            flack ? null,
            forceApp ? true,
            extraPaths ? [ ],

            # By default we shouldn't include flack in dependencies.
            loadAsFlake ? true,
            includeFlackInDependencies ? false,

            # If this isn't specified, we will use builtin builders,
            # which will preload the app but won't produce a closure in $out.
            pkgs ? null,
          }:
          let
            TAG = "mkClosure";

            # Get all the routable paths.
            routes = filter (update: update.method or null != null) updates;

            # Call into every path.
            results = concatMap (
              route:
              let
                inherit (route) method;
                path = joinPath route.path;

                # Helper for deepSeq.
                deep = x: deepSeq x x;

                # Get the whole result, and make a helper that returns a particular element from it.
                result = tryOrNull (app (mkPureEnv system method path));
                resultIdx = idx: if isList result && length result > idx then elemAt result idx else null;

                # Forces a value.
                # what: the log tag
                # isDeep: true if we should deeply evaluate the value. This is useful for the status code,
                # headers, and body, but less useful for the extra (where we want to deeply evaluate each entry
                # of the extra attrset independently from each other).
                # default: what to return if there is an eval error.
                # value: the value to force.
                force =
                  what: isDeep: default: value:
                  let
                    deep' = if isDeep then deep else x: x;
                    ret = tryOr default (deep' value);
                  in
                  if (default == null || typeOf ret == typeOf default) && ret != default then
                    Log.i TAG "${method} ${path} (${what}): returning ${tryOr "<error>" (toJSON ret)}" ret
                  else
                    Log.i TAG "${method} ${path} (${what}): returning default" default;

                # Force all of 'em.
                code = force "code" true 0 (resultIdx 0);
                headers = flatten (attrValues (force "headers" true { } (resultIdx 1)));
                body = force "body" true null (resultIdx 2);
                # We want to force every element of the extra independently.
                extra = attrValues (force "extra" false { } (resultIdx 3));

                toContext =
                  what: val:
                  let
                    # If we can't force the value deeply (e.g. it's nixpkgs, where this is a fool's errand)
                    # then just return the unforced val since it may still be useful as a path.
                    # Note that we just skip forcing the value deeply if it's a flake, since that will blow up memory usage
                    # and causes stack overflows on certain nixpkgs.
                    val' = force "string context for ${what}" (!(isFlakeInput val)) val val;
                  in
                  optional (isStringLike val') val';

                extra' = concatMap (toContext "extra") extra;
              in
              toContext "code" code
              ++ concatMap (toContext "headers") headers
              ++ toContext "body" body
              ++ parallel extra' extra'
            ) routes;

            closure = mkClosure {
              name = "${name}-flack-closure";
              inherit system pkgs;
              paths =
                optionals forceApp (parallel results (filter (result: result != null) results))
                ++ optionals (self != null) (
                  getInputsRecursive "self" self (
                    (optionals (!includeFlackInDependencies) [ "flack" ]) ++ devDependencies
                  )
                )
                ++ optionals (flack != null) [ flack.packages.${system}.default ]
                ++ getInputsRecursive "flack-lib" self' [ ]
                ++ extraPaths;
            };

            closure' =
              closure
              // optionalAttrs (pkgs != null && self != null && flack != null) {
                flack-serve = pkgs.stdenvNoCC.mkDerivation {
                  name = "${name}-flack-serve";
                  dontUnpack = true;

                  inherit self flack closure;

                  # We are explicitly overriding flack-lib (which is ourself).
                  flackLib = self';
                  flackServe = flack.packages.${system}.default;

                  closurePathNames = map (val: val.name) closure'.paths;
                  closurePaths = map (val: val.derivation or val.path) closure'.paths;

                  nativeBuildInputs = [ pkgs.makeWrapper ];

                  installPhase = ''
                    runHook preInstall
                    mkdir -p $out/bin $out/flack-support

                    # Override flack and flack-lib to whatever was provided.
                    makeWrapper $flackServe/bin/flack-serve $out/bin/flack-serve \
                      --add-flags "${if loadAsFlake then "--flake" else "--import"} $out/flack-support/app/" \
                      --add-flags "--override-input flack $out/flack-support/flack/" \
                      --add-flags "--override-input flack-lib $out/flack-support/lib/"

                    ln -s "$(realpath "$self")" $out/flack-support/app
                    ln -s "$(realpath "$flack")" $out/flack-support/flack
                    ln -s "$(realpath "$flackLib")" $out/flack-support/lib

                    mkdir -p $out/flack-support/closure
                    pushd .
                    cd $out/flack-support/closure
                    closureNamesArray=($closurePathNames)
                    closurePathsArray=($closurePaths)
                    for (( idx=0; idx < "''${#closurePathsArray[@]}"; idx++ )); do
                      name="''${closureNamesArray[idx]}"
                      path="''${closurePathsArray[idx]}"
                      dedup=1
                      base="$name"
                      while [ -e "$name" ]; do
                        name="$base-$dedup"
                        dedup=$((dedup+1))
                      done
                      ln -vsf "$(realpath "$path")" "$name"
                    done
                    popd
                    runHook postInstall
                  '';

                  doInstallCheck = true;

                  installCheckPhase = ''
                    runHook preInstallCheck
                    $out/bin/flack-serve --version | grep flack
                    runHook postInstallCheck
                  '';
                };
              };
          in
          Log.i TAG ''
            Closure of application '${name}' contains ${toString (length (closure'.paths or [ ]))} path(s).
            ${concatMapStringsSep "\n" (
              { name, path, ... }:
              "- ${if name == "" then toString path else name}${if name == "" then "" else ": ${toString path}"}"
            ) (closure'.paths or [ ])}
          '' closure';

        __functor =
          self: env:
          let
            req = mkReq self env;
            finalRes = foldl (
              finalReq: component:
              let
                finalReq' =
                  if finalReq.type == "req" then
                    if isReserved component then
                      # Reserved.
                      finalReq
                    else if hasAttr component finalReq.app then
                      # Explicit route.
                      finalReq // { app = finalReq.app.${component}; }
                    else if hasAttr pathPlaceholder finalReq.app then
                      # Placeholder.
                      finalReq // { app = finalReq.app.${pathPlaceholder}; }
                    else
                      # Don't recurse.
                      finalReq
                  else
                    finalReq;
              in
              if isFunction finalReq'.app || isFunctor finalReq'.app then
                execMiddleware finalReq' finalReq'.app
              else
                finalReq'
            ) req req.pathComponents;
          in
          if finalRes.type == "req" then
            # Unhandled; do so...
            (finalRes.res 404 { error = "No handler for route"; }).flack
          else
            finalRes.flack;
      };
    in
    app;

  flack = {
    mkApp =
      {
        name ? null,
        modules ? [ ],
        specialArgs ? { },
        mount ? { },
        use ? { },
        route ? { },
        devDependencies ? [ ],
      }:
      let
        implicitModule = {
          ${nullable (name != null) "name"} = name;
          ${nullable (mount != { }) "mount"} = mount;
          ${nullable (use != { }) "use"} = use;
          ${nullable (route != { }) "route"} = route;
          ${nullable (devDependencies != [ ]) "devDependencies"} = devDependencies;
        };
        providedModules = if isList modules then modules else singleton modules;
        evalResult = evalModules {
          modules = [ ./module.nix ] ++ providedModules ++ optional (implicitModule != { }) implicitModule;
          specialArgs = specialArgs // {
            inherit flack;
          };
        };
      in
      mkApp' evalResult.config;

    lib = flackLib;
  };
in
flack
