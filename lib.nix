{ lib }:

let
  inherit (lib.strings)
    toUpper
    replaceStrings
    splitString
    concatMapStringsSep
    hasPrefix
    hasSuffix
    normalizePath
    removeSuffix
    unescapeURL
    match
    ;

  inherit (lib.lists)
    length
    head
    tail
    singleton
    elemAt
    optional
    foldl
    ;

  inherit (lib.attrsets)
    isAttrs
    hasAttr
    ;

  inherit (lib.trivial) isFunction isInt;

  # Matches a query parameter (i.e. `foo=bar` or `foo`).
  splitQueryParam = match "^([^=&]+)(=([^&]*))?$";

  # Matches an array parameter (i.e. `foo[]`).
  matchArrayParam = match "^([^\\[]+)\\[]$";
in
rec {
  trivial = {
    # Returns true if the given value is an attrset containing a functor.
    isFunctor = val: isAttrs val && hasAttr "__functor" val && isFunction val.__functor;
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

  flack = {
    # Creates a Flack request object from the Flack environment.
    mkReq =
      app: env:
      let
        req = rec {
          type = "req";

          # Express-compatible attributes.
          inherit app env;
          params = { };
          body = env."flack.body" or { };
          host = env.HTTP_HOST;
          method = env.REQUEST_METHOD;
          path = env.PATH_INFO;
          pathComponents = paths.splitPath "/" path;
          protocol = env."rack.url_scheme";
          secure = protocol == "https";
          queryString = env.QUERY_STRING;
          query = queries.parseQuery queryString;
          get = header: env.${headers.normalizeHeader header} or null;
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
  };
}
