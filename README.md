# Flack

Write web applications using your [favorite reproducible configuration language](https://nixos.org).

Flack serves an HTTP server from your flakes using a [Rack](https://rack.github.io/rack/main/SPEC_rdoc.html)-inspired CGI gateway,
and provides a web router API written in Nix that works like [Express](https://expressjs.com/).

## Examples

- Check out the example app in `apps/default.nix`
- Run by either:
    - `nix run github:NixVegas/flack -- --flake github:NixVegas/flack`
    - Cloning, and `nix run`
- Browse to https://localhost:2019 and try an implementation of search.nixos.org in pure Nix
