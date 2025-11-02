{
  lib,
  flack,
  self,
  ...
}:

{
  mount = {
    "/pkgs" = {
      route.GET."/:...path" =
        req:
        let
          pkgs = self.legacyPackages.${req.system};
          pkg = lib.attrByPath req.params.path null pkgs;
          subPath =
            let
              names = lib.attrNames req.query;
            in
            if lib.length names == 1 then lib.strings.normalizePath ("/" + lib.head names) else "";
        in
        if pkg == null then req.res 400 else req.res 200 { } "${pkg}${subPath}";
    };
  };
  use = {
    "/foo" =
      req: if req.get "X-Auth-Token" != "supersecret" then req.res 401 { } "Unauthorized" else req;
  };
  route = {
    GET."/" = req: req.res 200 { "hello" = "world"; };
    GET."/foo/:bar" =
      req:
      req.res 200 { } {
        inherit (req) pathComponents;
        inherit (req.params) bar;
      };
    POST."/foo/:bar" = req: req.res 201 { inherit (req.params) bar; };
    GET."/baz" = req: req.res 200 { "baz" = "quux"; };
  };
}
