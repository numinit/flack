# Flack

Write web applications using your [favorite reproducible configuration language](https://nixos.org).

Flack serves an HTTP server from your flakes using a [Rack](https://rack.github.io/rack/main/SPEC_rdoc.html)-inspired CGI gateway,
and provides a web router API written in Nix that works like [Express](https://expressjs.com/).

## Experimental

Everything in this repo is subject to change. Don't put it into prod!

That being said, the module system API for Flack apps is likely fairly consistent.

## Examples

Check out the example app in [apps/default.nix](https://github.com/numinit/flack/blob/master/apps/default.nix).
It contains a partial search.nixos.org implementation, as well as examples of sandboxed CGI scripts, mounts,
middlewares, and normal routes.

- Run it by either:
    - `nix run github:numinit/flack -- --flake github:numinit/flack`
    - Cloning, and `nix run`
- Browse to http://localhost:2019 and try an implementation of search.nixos.org in pure Nix
