{
  self,
  lib,
  inputs,
}:

let
  inherit (builtins)
    storeDir
    getContext
    tryEval
    trace
    traceVerbose
    addErrorContext
    ;

  inherit (lib.strings)
    isString
    toUpper
    replaceStrings
    splitString
    concatStringsSep
    concatMapStringsSep
    hasPrefix
    hasSuffix
    normalizePath
    removeSuffix
    unescapeURL
    unsafeDiscardStringContext
    match
    parseDrvName
    ;

  inherit (lib.lists)
    isList
    length
    head
    tail
    any
    concatMap
    singleton
    elemAt
    optional
    foldl
    imap1
    ;

  inherit (lib.attrsets)
    isAttrs
    hasAttr
    attrNames
    attrValues
    foldlAttrs
    mergeAttrsList
    ;

  inherit (lib.trivial)
    isFunction
    isInt
    warn
    ;

  inherit (lib.asserts) assertMsg;

  # Matches a query parameter (i.e. `foo=bar` or `foo`).
  splitQueryParam = match "^([^=&]+)(=([^&]*))?$";

  # Matches an array parameter (i.e. `foo[]`).
  matchArrayParam = match "^([^\\[]+)\\[]$";

  flackLib = {
    trivial = {
      # Returns true if the given value is an attrset containing a functor.
      isFunctor = val: isAttrs val && hasAttr "__functor" val && isFunction val.__functor;

      # Returns true if the given value looks like a flake.
      isFlakeInput = val: isAttrs val && val ? "outPath";

      # Returns null if the first parameter is false, otherwise the second parameter.
      nullable = condition: val: if condition then val else null;

      # Returns the value if it's an integer, otherwise 0.
      coerceInt = val: if isInt val then val else 0;

      # Unwraps a tryEval result, returning default on failure.
      tryOr =
        default: val:
        let
          inherit (flackLib.trivial) tryOr';
          catch = tryOr' default val;
        in
        catch.value;

      # The same as tryOr, but doesn't eagerly return the value, preventing some potential errors.
      tryOr' =
        default: val:
        let
          catch = tryEval val;
        in
        if catch.success == true then catch else catch // { value = default; };

      # Unwraps a tryEval result, defaulting to null.
      tryOrNull = flackLib.trivial.tryOr null;

      # The same as tryOrnull, but doesn't eagerly force the value.
      tryOrNull' = flackLib.trivial.tryOr' null;
    };

    strings = rec {
      # Returns true if the given attrset key is reserved (i.e. starts with _ or ends with ').
      isReserved = val: hasPrefix "_" val || hasSuffix "'" val;

      # Converts the empty string or not a string to null.
      emptyToNull = x: if x == "" || !(isString x) then null else x;

      # Converts null or not a string to the empty string.
      nullToEmpty = x: if x == null || !(isString x) then "" else x;

      # Returns the value if it's a string, otherwise the empty string.
      coerceString = val: if isString val then val else "";

      # Matches a store path.
      matchStorePath = match "^(${storeDir}/([^/]+)).*";

      # Matches a store name (e.g. b81gjzg6cy3n51gk3jhrylyqkpdx91nl-foo-bar-version).
      matchStoreName = match "^([^-]+)-(.+)$";

      # Parses a store path into an attrset of {hash = <...>; name = <...>; version = <...>;}.
      # If there is no version, version is an empty string.
      parseStorePath =
        val:
        let
          storeMatch = matchStorePath (toString val);
        in
        if storeMatch != null && length storeMatch > 1 then
          let
            nameMatch = matchStoreName (elemAt storeMatch 1);
          in
          if nameMatch != null && length nameMatch > 1 then
            { hash = head nameMatch; } // parseDrvName (elemAt nameMatch 1)
          else
            null
        else
          null;
    };

    lists = {
      # Returns the value if it's a list, otherwise the empty list.
      coerceList = val: if isList val then val else [ ];

      # Parallel eval helper, falling back to builtins.seq if parallel eval is unsupported.
      parallel =
        if builtins ? parallel then
          builtins.parallel
        else
          assert Log.w' "parallel" "builtins.parallel is unsupported, using builtins.seq instead";
          builtins.seq;
    };

    # Normalizes a header name (i.e. x-forwarded-for becomes HTTP_X_FORWARDED_FOR).
    headers = {
      normalizeHeader =
        header:
        let
          normalized = replaceStrings [ "-" ] [ "_" ] (toUpper header);
        in
        if normalized == "CONTENT_TYPE" || normalized == "CONTENT_LENGTH" then
          normalized
        else
          "HTTP_${normalized}";
    };

    verbs =
      let
        verbList = [
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
        verbRegex = "^(${concatMapStringsSep "|" toUpper verbList})$";
      in
      rec {
        # Matches a HTTP verb.
        matchVerb = match verbRegex;

        # Returns true if the given verb is valid.
        isVerb = verb: matchVerb verb != null;
      };

    paths = rec {
      # The placeholder. In the future, may be extended to "%.ext".
      pathPlaceholder = "%";

      # Returns a normalized path - that is, one with a leading and trailing /.
      # Deletes consecutive slashes.
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

      # Joins the specified path.
      joinPath = path: normalizePath ("/" + concatStringsSep "/" path);

      # Joins the specified path, converting "/" to "/index.html".
      joinPathToIndex =
        path:
        let
          joinedPath = joinPath path;
        in
        if joinedPath == "/" then "/index.html" else joinedPath;

      # Matches a path component.
      matchPathComponent = match "^[^/]+$";

      # Matches a path component containing a route placeholder.
      matchRoutePlaceholder = match "^:(\\.\\.\\.)?([^./]+)$";
    };

    queries = {
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
    };

    log = {
      mkLog =
        tag:
        let
          mkMsg =
            level: fn: msg:
            "${tag}\t${fn}\t${level}\t${msg}";
        in
        rec {
          d =
            fn: msg: ret:
            traceVerbose (mkMsg "D" fn msg) ret;
          d' = fn: msg: d fn msg true;
          i =
            fn: msg: ret:
            trace (mkMsg "I" fn msg) ret;
          i' = fn: msg: i fn msg true;
          w =
            fn: msg: ret:
            warn (mkMsg "W" fn msg) ret;
          w' = fn: msg: w fn msg true;
          e =
            fn: msg: ret:
            let
              msg = mkMsg "E" fn msg;
            in
            addErrorContext msg (warn msg ret);
          e' = fn: msg: e fn msg true;
        };
    };

    flack = {
      # Creates a Flack request object from the Flack environment.
      mkReq =
        app: env:
        let
          inherit (flackLib.paths) splitPath;
          inherit (flackLib.queries) parseQuery;
          inherit (flackLib.headers) normalizeHeader;

          req = rec {
            type = "req";

            # Express-compatible attributes.
            inherit app env;
            params = { };
            body = env."flack.body" or { };
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
                extra = 4;
              in
              {
                type = "res";
                inherit req app;

                stage = 0;
                code = 200;
                headers = { };
                body = null;
                extra = { };

                # Progresses res to the next stage (code, body, or body with headers).
                __functor =
                  self: value:
                  if self.stage < code then
                    assert isInt value;
                    self
                    // rec {
                      stage = self.stage + 1;
                      code = value;
                      flack = [
                        code
                        { }
                        null
                      ];
                    }
                  else if self.stage < headers then
                    self
                    // rec {
                      stage = self.stage + 1;
                      body = value;
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
                      body = value;
                      flack = [
                        self.code
                        headers
                        body
                      ];
                    }
                  else if self.stage < extra then
                    self
                    // rec {
                      stage = self.stage + 1;
                      extra = value;
                      flack = self.flack ++ singleton extra;
                    }
                  else
                    self;
              };

            # Flack attributes.
            id = env."flack.request_id";
            timestamp = env."flack.request_timestamp";
            system = env."flack.system";
            overrideInput = input: env."flack.override.${input}" or null;
          };
        in
        req;

      # Returns a pure request environment for the specified system, method and path.
      mkPureEnv =
        system: method: path:
        let
          impure = throw "impure request data";
        in
        {
          HTTP_HOST = impure;
          REQUEST_METHOD = method;
          PATH_INFO = path;
          QUERY_STRING = impure;
          "rack.url_scheme" = impure;
          "flack.request_id" = impure;
          "flack.request_timestamp" = impure;
          "flack.system" = system;
          "flack.body" = impure;
        };

      # Returns the closure for the given system and store paths without using nixpkgs,
      # if pkgs is null.
      #
      # If pkgs is null, it will simply result in a directory that contains multiple
      # `preload-$n/complete` links with the contents `1`.
      #
      # If pkgs isn't null, it properly calls closureInfo.
      #
      # We use the first way for preloading the app so we don't need a full nixpkgs.
      # For bundling the app, we properly compute the closure.
      mkClosure =
        {
          name,
          system,
          paths,
          pkgs ? null,
        }:
        assert assertMsg (pkgs != null -> pkgs.stdenv.buildPlatform.system == system) ''
          the build platform of pkgs (${pkgs.stdenv.buildPlatform.system}) was not equal to ${system}
        '';
        let
          TAG = "mkClosure";

          inherit (flackLib.strings) matchStorePath parseStorePath;

          # Picks out the unique root store paths from the input, with a consistent ordering.
          filteredPaths = attrValues (
            mergeAttrsList (
              concatMap (
                path:

                let
                  hasName = isAttrs path && path.name or null != null && path.path or null != null;

                  path' =
                    if hasName then
                      # Named path
                      path.path
                    else
                      # Raw path
                      path;

                  name =
                    if hasName then
                      # We have the name (perhaps because it was a flake input).
                      path.name
                    else
                      # No friendlier name available.
                      let
                        pathMatch = parseStorePath path';
                      in
                      if pathMatch == null then "" else pathMatch.name;

                  match = matchStorePath (toString path');

                  context =
                    let
                      context' = getContext (toString path');
                      drvs = attrNames context';
                      inherit (flackLib.trivial) tryOrNull;
                    in
                    concatMap (
                      sp:
                      let
                        info = context'.${sp};
                      in
                      if info ? path && info.path == true then
                        # Raw store path.
                        singleton sp
                      else if info ? outputs && isList info.outputs then
                        # Use the selected outputs.
                        let
                          drv = tryOrNull (import sp);
                        in
                        if drv == null then
                          assert Log.w' TAG "error importing derivation '${sp}'";
                          [ ]
                        else
                          let
                            outputs' = map (output: drv.${output}) info.outputs;
                          in
                          if length outputs' < 1 then
                            assert Log.w' TAG "store path '${sp}' had no outputs!";
                            singleton sp
                          else
                            outputs'
                      else
                        # Not sure what to do with this.
                        assert Log.w' TAG "store path '${sp}' neither was a path nor had outputs";
                        [ ]
                    ) drvs;
                in
                if match != null && length match > 0 then
                  # Looks like a store path, get all the string contexts.
                  let
                    context' = map (path: {
                      ${unsafeDiscardStringContext (toString path)} = {
                        inherit name path;
                        derivation = path';
                      };
                    }) context;
                  in
                  if length context' < 1 then
                    # This appears to happen for input overrides.
                    assert Log.w' TAG "store path '${name}' (${path'}) had no context, using as-is";
                    singleton {
                      ${head match} = {
                        inherit name;
                        path = head match;
                        derivation = path';
                      };
                    }
                  else
                    context'
                else
                  assert Log.d' TAG "path '${name}' (${path'}) didn't look like a store path";
                  [ ]
              ) paths
            )
          );

          annotate =
            env:
            env
            // {
              # The root paths (before they were turned into preloads).
              paths = filteredPaths;

              # Causes infinite recursion if unset.
              flackDontIndex = true;
            };
        in
        if pkgs == null then
          let
            # Creates a single preload using a dumb unpack-channel.
            # Note that the path won't be in the runtime closure, but will be in the build closure.
            # (But this is good enough, since it is just used to preload the app).
            mkPreload =
              preloadName:
              { name, path, ... }:
              derivation {
                name = if name == "" then "preload" else "${name}-preload";
                builder = "builtin:unpack-channel";
                channelName = preloadName;
                buildInputs = [ path ];

                # This simply creates '$out/$name/complete'
                src = ./preload.tar;

                inherit system;
              };

            # Converts all the paths to preloads.
            filteredPreloads = imap1 (idx: val: mkPreload "preload-${toString idx}" val) filteredPaths;

            # Builds an environment that contains all the preloads.
            env = derivation {
              name = "${name}-env";
              builder = "builtin:buildenv";
              derivations = [
                true # active
                10 # priority
                (length filteredPreloads)
              ]
              ++ filteredPreloads;
              buildInputs = filteredPreloads;

              manifest = "/dev/null";
              inherit system;
            };
          in
          annotate env
        else
          # Normal closureInfo if we have pkgs (i.e. we aren't preloading).
          (annotate (
            pkgs.closureInfo {
              rootPaths = map (path: path.path) filteredPaths;
            }
          ));

      # Computes all the unique transitive input dependencies for a given flake,
      # except for the ones with the given names.
      #
      # Returns a list of {name = <...>; path = <...>;}.
      getInputsRecursive =
        name: flake: exceptFor:
        let
          TAG = "getInputsRecursive";

          inherit (flackLib.trivial)
            isFlakeInput
            tryOr
            ;

          recursiveInputsFor =
            seen: name: root:
            if isFlakeInput root then
              let
                root' = unsafeDiscardStringContext (toString root.outPath);
              in
              if
                any (val: name == val || val ? outPath && root.outPath == val.outPath) exceptFor
                || hasAttr root' seen
              then
                # Don't repeat this path, or it's in our denylist
                assert Log.d' TAG "skipped input: ${name}";
                seen
              else
                assert Log.d' TAG "added input: ${name} -> ${root.outPath}";
                # Add it and all its inputs recursively
                let
                  seen' = seen // {
                    ${root'} = {
                      inherit name;
                      path = root.outPath;
                    };
                  };
                in
                foldlAttrs recursiveInputsFor seen' (tryOr { } (root.inputs or { }))
            else
              # Not a flake; ignore it.
              assert Log.d' TAG "input ${name} was not a flake";
              seen;
        in
        attrValues (recursiveInputsFor { } name flake);
    };
  };

  Log = flackLib.log.mkLog "flack-lib";
in
flackLib
