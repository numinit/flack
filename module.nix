{ lib, flack, ... }:

let
  inherit (lib) types;

  inherit (lib.lists) all head tail;

  inherit (lib.attrsets) attrNames;

  inherit (lib.options) mkOption;

  inherit (flack.lib.verbs) isVerb;

  inherit (flack.lib.paths) splitPath matchPathComponent matchRoutePlaceholder;

  # Creates a type that's an attribute set with keys matching the given predicate.
  attrsWithKeysOf =
    keyPredicate: type:
    let
      prev = types.attrsOf type;
    in
    prev
    // {
      check = val: prev.check val && all keyPredicate (attrNames val);
      merge = opts: prev.merge opts;
    };

  # Creates a type that's a router (i.e. all keys are paths or placeholders).
  routerOf =
    let
      isPathComponent =
        component: matchPathComponent component != null || matchRoutePlaceholder component != null;
      isPath =
        path:
        let
          split = splitPath "/" path;
        in
        head split == "/" && all isPathComponent (tail split);
    in
    attrsWithKeysOf isPath;

  # Creates a type that is an attrset only containing HTTP verbs.
  verbsOf = attrsWithKeysOf isVerb;

  # Creates a type that's a Flack handler.
  handler = with types; functionTo attrs;

  # The toplevel app type.
  app = {
    use = mkOption {
      type = routerOf handler;
      default = { };
    };
    route = mkOption {
      type = verbsOf (routerOf handler);
      default = { };
    };
    mount = mkOption {
      type = routerOf (
        types.submodule {
          options = app;
        }
      );
      default = { };
    };
  };
in
{
  options = app;
}
