# Flack

Write web applications using your [favorite reproducible configuration language](https://nixos.org).

Flack serves an HTTP server from Nix projects using a [Rack](https://rack.github.io/rack/main/SPEC_rdoc.html)-inspired CGI gateway,
and provides a web router API written in Nix that works like [Express](https://expressjs.com/) and [Sinatra](https://sinatrarb.com/).

Flack works with both flakes and non-flakes, using [idc](https://github.com/jakehamilton/idc) to load projects that it can't natively
load with Nix.

## Experimental

Everything in this repo is subject to change. Don't put it into prod.
Nix hasn't had its evaluator threads exposed to the internet before.

Flack will lose its "experimental" status when I get seccomp sandboxing
for the evaluator working (and I am comfortable exposing it to the internet
even if the eval process gets compromised). Please only run it on localhost for now.

That being said, the module system API for Flack apps is likely fairly consistent.

※ I find documentation applications a bit less technically enjoyable than sandboxing.
 If you'd like to help with documentation backends, get in touch.
 Documentation applications will likely be in a separate repo soon.

## Flakes

Here's an example with flakes. Use `--flake` as your flake ref and (optionally)
`--dir` as the directory to load it from. `--dir` defaults to `.`.

```nix
# flake.nix
# Run with `nix run github:numinit/flack` and visit http://localhost:2020
{
    inputs.flack.url = "github:numinit/flack";

    outputs = { flack, ... }: {
        flack.apps.default = flack.mkApp {
            route = {
                GET."/" = req: req.res 200 "Hello, Flack!";
            };
        };

        # In case you want `nix run` to work on your local flake, too:
        inherit (flack) apps;
    };
}
```

## Anything else

For non-flakes, so long as `idc` can load it and you expose an attribute with
a Flack app, it will probably work. Use `--import` and/or `--dir` to point Nix
at the directory or file to load. This also works fine with flakes.

## Examples

Check out the example app in [apps/default.nix](https://github.com/numinit/flack/blob/master/apps/default.nix).
It contains a partial search.nixos.org implementation, as well as examples of sandboxed CGI scripts, mounts,
middlewares, and normal routes.

Run it by either:
    - `nix run github:numinit/flack -- --flake github:numinit/flack`
    - Cloning, and `nix run`

Then you can browse to http://localhost:2020 and try an implementation of search.nixos.org in pure Nix
