{ lib }:

let
  methods = [
    "checkout"
    "copy"
    "delete"
    "get"
    "head"
    "lock"
    "m-search"
    "merge"
    "mkactivity"
    "mkcol"
    "move"
    "notify"
    "options"
    "patch"
    "post"
    "purge"
    "put"
    "report"
    "search"
    "subscribe"
    "trace"
    "unlock"
    "unsubscribe"
  ];
  /*
    A Flack router looks like the following:
    {
      mount."/according/:to" = { (process recursively with that as a prefix) };

      use."/all/known" = req: ...;

      route = {
        GET."/all/known/:laws/of" = req: ...;
        POST."/aviation" = req: ...;
        PATCH."/there/is/no/way/a/bee/should/be/able/to/fly" = req: ...;
      };
    }

    At any given level, the default next function simply recurses, handling each component of the URL
    in turn. This lets us override this behavior with middleware that can intercept each request before the
    next function is called.
    {
      all.known."".of = { type = "GET"; __functor = req: ... };
      aviation = { type = "POST"; __functor = req: ... };
      there.is.no.way.a.bee.should.be.able.to.fly = { type = "PATCH"; __functor = req: ...; };
    }

    Middlewares are supported through fixpoints. Note that req is more like a "finalReq":
  */

  inherit (lib.modules) evalModules;

  inherit (lib.strings)
    toUpper
    replaceStrings
    splitString
    hasPrefix
    hasSuffix
    normalizePath
    removeSuffix
    escapeURL
    unescapeURL
    concatMapStringsSep
    match
    ;

  inherit (lib.lists)
    isList
    length
    head
    tail
    singleton
    elemAt
    optional
    foldl
    flatten
    toposort
    sublist
    dropEnd
    genList
    ;

  inherit (lib.attrsets)
    isAttrs
    hasAttr
    foldlAttrs
    mapAttrs
    mapAttrsToList
    updateManyAttrsByPath
    ;

  inherit (lib.trivial) isFunction isInt;

  j = builtins.toJSON;
  t = x: builtins.trace x x;
  t2 = builtins.trace;
  tj = x: builtins.trace (builtins.toJSON x) x;

  isFunctor = val: isAttrs val && hasAttr "__functor" val && isFunction val.__functor;

  # Normalizes a header name (i.e. x-forwarded-for becomes HTTP_X_FORWARDED_FOR).
  normalizeHeader =
    header:
    let
      normalized = replaceStrings [ "-" ] [ "_" ] (toUpper header);
    in
    if normalized == "CONTENT_TYPE" || normalized == "CONTENT_LENGTH" then
      normalized
    else
      "HTTP_${normalized}";

  # Matches a query parameter (i.e. `foo=bar` or `foo`).
  splitQueryParam = match "^([^=&]+)(=([^&]*))?$";

  # Matches an array parameter (i.e. `foo[]`).
  matchArrayParam = match "^([^\\[]+)\\[]$";

  # Parses a query string into an attrset.
  parseQuery =
    query:
    foldl (
      s: x:
      let
        split = splitQueryParam x;
        key = if split == null then null else unescapeURL (head split);

        array =
          if key == null then
            null
          else
            let
              arrayMatch = matchArrayParam key;
            in
            if arrayMatch == null then null else head arrayMatch;

        value = if split == null || length split != 3 then null else unescapeURL (elemAt split 2);
      in
      if array == null then
        # Handle normal values (including replacements).
        s // { ${key} = value; }
      else
        # Handle arrays.
        s
        // {
          ${array} =
            let
              existingValue = s.${array} or [ ];
            in
            existingValue ++ (optional (value != null) value);
        }
    ) { } (splitString "&" query);

  # Creates a request.
  mkReq =
    app: env:
    let
      req = rec {
        type = "req";

        # Express-compatible attributes.
        inherit app env;
        params = { };
        host = env.HTTP_HOST;
        method = env.REQUEST_METHOD;
        path = env.PATH_INFO;
        pathComponents = splitPath "/" path;
        protocol = env."rack.url_scheme";
        secure = protocol == "https";
        queryString = env.QUERY_STRING;
        query = parseQuery queryString;
        get = header: env.${normalizeHeader header} or null;
        xhr = get "X-Requested-With" == "XMLHttpRequest";

        # The response object (req.res)
        res =
          let
            code = 1;
            headers = 2;
            body = 3;
          in
          {
            type = "res";
            inherit req app;

            stage = 0;
            code = 200;
            headers = { };
            body = null;

            # Progresses res to the next stage (code, body, or body with headers).
            __functor =
              self: codeHeadersOrBody:
              if self.stage < code then
                assert isInt codeHeadersOrBody;
                self
                // rec {
                  stage = self.stage + 1;
                  code = codeHeadersOrBody;
                  flack = [
                    code
                    { }
                    null
                  ];
                }
              else if self.stage < headers then
                assert isAttrs codeHeadersOrBody;
                self
                // rec {
                  stage = self.stage + 1;
                  body = codeHeadersOrBody;
                  flack = [
                    self.code
                    { }
                    body
                  ];
                }
              else if self.stage < body then
                self
                // rec {
                  stage = self.stage + 1;
                  headers = self.body;
                  body = codeHeadersOrBody;
                  flack = [
                    self.code
                    self.headers
                    body
                  ];
                }
              else
                self;
          };

        # Flack attributes.
        id = env."flack.request_id";
        system = env."flack.system";
      };
    in
    req;

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

  # Returns a normalized path - that is, one with a leading and trailing / that can be toposorted.
  mkNormalizedPath =
    prefix: path:
    let
      # Normalizes the prefix.
      normalizedPrefix =
        if prefix == "/" then
          # Fast path for routing.
          prefix
        else
          # Slow path for route building.
          let
            fixedPrefix = if hasPrefix "/" prefix then prefix else "/${prefix}";
          in
          if hasSuffix "/" fixedPrefix then fixedPrefix else "${fixedPrefix}/";
    in
    normalizePath (normalizedPrefix + path + "/");

  # Returns a list that looks like: [ "/" "foo" "bar" "baz" ]
  splitPath =
    prefix: path:
    singleton "/" ++ tail (splitString "/" (removeSuffix "/" (mkNormalizedPath prefix path)));

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
      matchComponent = match "^:(\\.\\.\\.)?([^./]+)$";
    in
    foldl (
      s: x:
      let
        isSplat = length s > 0 && (elemAt s (length s - 1)).splat;
        isLast = length x == length pathComponents;
        componentMatch = matchComponent (elemAt x (length x - 1));
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
              path' = dropEnd 1 x ++ singleton "";
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
              path' = x;
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
          if req.method == method && length req.pathComponents == length (splitPath prefix path) then
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

  mkApp =
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
          (finalRes.res 404 { } "Not found").flack
        else
          finalRes.flack;
    };
in
{
  inherit mkApp;
}
