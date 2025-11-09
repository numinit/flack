lib:

let
  inherit (lib.modules) evalModules;

  inherit (lib.strings)
    hasSuffix
    optionalString
    ;

  inherit (lib.lists)
    isList
    length
    optional
    singleton
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
    foldlAttrs
    mapAttrs
    mapAttrsToList
    optionalAttrs
    updateManyAttrsByPath
    ;

  inherit (lib.trivial) isFunction;

  flackLib = import ./lib.nix {
    inherit lib;
  };

  inherit (flackLib.trivial) isFunctor;
  inherit (flackLib.paths) splitPath;
  inherit (flackLib.flack) mkReq;

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
  # [ { param = "foo"; splat = false; path = [ "/" "foo" "" ]; __functor = (resolves this node); }
  #   { param = null; splat = true; path = [ "/" "foo" "" "baz" ]; __functor = (resolves the terminal node) } ]
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
        mkPath = map (val: optionalString (matchRoutePlaceholder val == null) val);
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
                if self.param' != null && (elemAt self.path' pathIdx) == "" then
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
    prefix: pathFns:
    let
      routers = flatten (mapAttrsToList (mkRouters prefix) pathFns);
      sortedRouters = toposort (prefix: val: lib.lists.hasPrefix prefix.path' val.path') routers;
    in
    # Creates the list of updates.
    map (router: {
      path = router.path';
      update =
        val:
        let
          res = builtins.tryEval val;
        in
        mkMiddleware (if res.success then res.value else null) router;
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
      uses = mkRouterUpdates prefix use;

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
        s ++ mkRouterUpdates prefix (annotateRoutes method routeFns)
      ) [ ] route;
    in
    mounts ++ uses ++ flattenedRoutes;

  mkApp' =
    {
      mount ? { },
      use ? { },
      route ? { },
    }@args:
    updateManyAttrsByPath (mkAppUpdates "/" args) {
      __functor =
        self: env:
        let
          req = mkReq self env;
          finalRes = foldl (
            finalReq: component:
            let
              finalReq' =
                if finalReq.type == "req" then
                  if component == "__functor" || hasSuffix "'" component then
                    # Reserved.
                    finalReq
                  else if hasAttr component finalReq.app then
                    # Explicit route.
                    finalReq // { app = finalReq.app.${component}; }
                  else if hasAttr "" finalReq.app then
                    # Placeholder.
                    finalReq // { app = finalReq.app.""; }
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
          (finalRes.res 404 { } { error = "No handler for route"; }).flack
        else
          finalRes.flack;
    };

  flack = {
    mkApp =
      {
        modules ? [ ],
        specialArgs ? { },
        mount ? { },
        use ? { },
        route ? { },
      }:
      let
        implicitModule =
          optionalAttrs (mount != { }) {
            inherit mount;
          }
          // optionalAttrs (use != { }) {
            inherit use;
          }
          // optionalAttrs (route != { }) {
            inherit route;
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
