{
  lib,
  inputs,
  ...
}:

# This application demos mounts, middlewares, and routes.
#
# Note that we expose it with:
# flack.apps.default = flack.mkApp {
#   imports = [ ./apps ];
#   specialArgs = { inherit self; };
# }
#
# You can access flack.lib if you add flack as a flake input.
#
# By default, flack serves flack.apps.default, though this can be changed
# on the command line of flack-serve.
{
  mount = {
    /*
      This is a mountpoint.
      GET /pkgs/attr/path?filename will fetch a file within a package,
      after realising that derivation
    */
    "/pkgs" = {
      # Note how this file serves a store path, and it gets automatically realised :-)
      route.GET."/:...path" =
        req:
        let
          # Current system is in `req.system`.
          pkgs = inputs.nixpkgs.legacyPackages.${req.system};

          # req.params.path is automatically a list of path components with :...foo syntax
          pkg = lib.attrByPath req.params.path null pkgs;
          subPath =
            let
              names = lib.attrNames req.query;
            in
            if lib.length names == 1 then lib.strings.normalizePath ("/" + lib.head names) else "";
        in
        if pkg == null then req.res 400 else req.res 200 { } "${pkg}${subPath}";
    };

    /* Uh-oh... */
    "/cgi-bin" =
      let
        getNow =
          req:
          let
            inherit (inputs.nixpkgs.legacyPackages.${req.system}) runCommandNoCC;
          in

          # We can use req.id as a source of nondeterminism...
          runCommandNoCC "now.txt" { inherit (req) id; } ''
            echo -n "$(date)" > $out
          '';
      in
      {
        route.GET = {
          "/now.cgi" =
            req:
            # We can serve a derivation directly, Flack figures it out.
            req.res 200 { } (getNow req);
          "/now.json" =
            req:
            # Here we serve a JSON body using readFile.
            req.res 200 { } { now = lib.readFile (getNow req); };
        };
      };
  };

  use = {
    /*
      This is a middleware.
      If X-Auth-Token isn't "supersecret" then it'll return a 401 for all paths under /foo.
      Obviously there is a timing sidechannel here, don't actually do this.
    */
    "/foo" =
      req: if req.get "X-Auth-Token" != "supersecret" then req.res 401 { } "Unauthorized" else req;
  };
  route = {
    /*
      This is a route.
      bar is available in req.params.
      Note the auth token above!
      `curl -H 'X-Auth-Token: supersecret' http://localhost:2019/foo/myBar`
    */
    GET."/foo/:bar" =
      req:
      req.res 200 { "X-My-Header" = "value"; } {
        inherit (req) pathComponents;
        inherit (req.params) bar;
      };

    /*
      This route reflects the JSON payload (req.body) at the user.
      Note the auth token above!
      `curl -X POST -H 'X-Auth-Token: supersecret' -H 'Content-Type: application/json' \
       -d '{"baz": "quux"}' http://localhost:2019/foo/myBar`
    */
    POST."/foo/:bar" =
      req:
      req.res 201 {
        inherit (req.params) bar;
        inherit (req) body;
      };

    # This is another route. We can omit headers if we just want a JSON body.
    GET."/" = req: req.res 200 "Hello, Flack!\n";
  };
}
