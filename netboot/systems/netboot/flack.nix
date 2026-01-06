{
  config,
  pkgs,
  ...
}:

{
  services.flack.servers.default = {
    enable = true;
    host = "0.0.0.0";
    openFirewall = true;
    closure = pkgs.flack-closure-netboot;
  };
}
