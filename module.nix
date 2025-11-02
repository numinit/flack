{ lib, ... }:

let
  inherit (lib) types;

  inherit (lib.options) mkOption;

  handler = with types; functionTo attrs;

  app = {
    use = mkOption {
      type = with types; attrsOf handler;
      default = { };
    };
    route = mkOption {
      type = with types; attrsOf (attrsOf handler);
      default = { };
    };
    mount = mkOption {
      type = types.attrsOf (
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
