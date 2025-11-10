# floc (flackdoc)

An implementation of the search.nixos.org Elasticsearch API in pure Nix.

`nix run github:numinit/flack -- --flake github:numinit/flack?dir=search`

## Notes

The first request on each channel may take up to 30 seconds to load as nixpkgs is evaluated.
Subsequent requests will be fast.
