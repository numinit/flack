/*
  Adapted from jakehamilton/idc: https://github.com/jakehamilton/idc

  Licensed under the Apache License 2.0:

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing,
  software distributed under the License is distributed on an
  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
  KIND, either express or implied.  See the License for the
  specific language governing permissions and limitations
  under the License.
*/
let
  /*
    Copyright (c) 2020-2021 Eelco Dolstra and the flake-compat contributors

    Permission is hereby granted, free of charge, to any person obtaining
    a copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
    LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
    OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
    WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
  */
  flake-compat =
    let
      lib = {
        attrs = {
          when = condition: set: if condition then set else { };

          pick = name: set: lib.attrs.when (set ? ${name}) { ${name} = set.${name}; };
        };

        strings = {
          when = condition: string: if condition then string else "";
        };

        hash = {
          from = {
            info = set: lib.attrs.when (set ? narHash) { sha256 = set.narHash; };
          };
        };

        date = {
          from = {
            modified =
              timestamp:
              let
                rem = x: y: x - x / y * y;
                days = timestamp / 86400;
                secondsInDay = rem timestamp 86400;
                hours = secondsInDay / 3600;
                minutes = (rem secondsInDay 3600) / 60;
                seconds = rem timestamp 60;

                # Courtesy of https://stackoverflow.com/a/32158604.
                z = days + 719468;
                era = (if z >= 0 then z else z - 146096) / 146097;
                doe = z - era * 146097;
                yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
                y = yoe + era * 400;
                doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
                mp = (5 * doy + 2) / 153;
                d = doy - (153 * mp + 2) / 5 + 1;
                m = mp + (if mp < 10 then 3 else -9);
                y' = y + (if m <= 2 then 1 else 0);

                pad = s: if builtins.stringLength s < 2 then "0" + s else s;
              in
              "${builtins.toString y'}${pad (builtins.toString m)}${pad (builtins.toString d)}${pad (builtins.toString hours)}${pad (builtins.toString minutes)}${pad (builtins.toString seconds)}";
          };
        };

        info = {
          from = {
            path = path: {
              type = "path";
              lastModified = 0;
              inherit path;
            };

            # TODO: Do we need support for other types?
          };
        };
      };

      fetchurl =
        { url, sha256 }:
        builtins.path {
          name = "source";
          recursive = true;
          path = builtins.derivation {
            builder = "builtin:fetchurl";

            name = "source";
            inherit url;

            executable = false;
            unpack = false;
            system = "builtin";
            preferLocalBuild = true;

            outputHash = sha256;
            outputHashAlgo = "sha256";
            outputHashMode = "recursive";

            impureEnvVars = [
              "http_proxy"
              "https_proxy"
              "ftp_proxy"
              "all_proxy"
              "no_proxy"
            ];

            urls = [ url ];
          };
        };

      fetch =
        info:
        if info.type == "path" then
          {
            outPath = builtins.path (
              {
                name = "source";
                inherit (info) path;
              }
              // lib.hash.from.info info
            );
          }
        else if info.type == "file" then
          if
            builtins.substring 0 7 info.url == "http://" || builtins.substring 0 8 info.url == "https://"
          then
            {
              outPath = fetchurl (
                {
                  inherit (info) url;
                }
                // lib.hash.from.info info
              );
            }
          else if builtins.substring 0 7 info.url == "file://" then
            {
              outPath = builtins.path (
                {
                  name = "source";
                  path = builtins.substring 7 (-1) info.url;
                }
                // lib.hash.from.info info
              );
            }
          else
            builtins.throw ''Unsupported input url "${info.url}"''
        else if info.type == "tarball" then
          {
            outPath = builtins.fetchTarball ({ inherit (info) url; } // lib.hash.from.info info);
          }
        else if info.type == "git" then
          {
            outPath = builtins.fetchGit (
              {
                inherit (info) url;
              }
              // lib.attrs.pick "rev" info
              // lib.attrs.pick "ref" info
              // lib.attrs.pick "submodules" info
            );

            inherit (info) lastModified;
            lastModifiedDate = lib.date.from.modified info.lastModified;
            revCount = info.revCount or 0;
          }
          // lib.attrs.when (info ? rev) {
            inherit (info) rev;
            shortRev = builtins.substring 0 7 info.rev;
          }
        else if info.type == "github" then
          {
            outPath = builtins.fetchTarball (
              {
                url = "https://api.${info.host or "github.com"}/repos/${info.owner}/${info.repo}/tarball/${info.rev}";
              }
              // lib.hash.from.info info
            );

            inherit (info) rev lastModified;
            shortRev = builtins.substring 0 7 info.rev;
            lastModifiedDate = lib.date.from.modified info.lastModified;
          }
        else if info.type == "gitlab" then
          {
            outPath = builtins.fetchTarball (
              {
                url = "https://${info.host or "gitlab.com"}/api/v4/projects/${info.owner}%2F${info.repo}/repository/archive.tar.gz?sha=${info.rev}";
              }
              // lib.hash.from.info info
            );

            inherit (info) rev lastModified;
            shortRev = builtins.substring 0 7 info.rev;
            lastModifiedDate = lib.date.from.modified info.lastModified;
          }
        else if info.type == "sourcehut" then
          {
            outPath = builtins.fetchTarball (
              {
                url = "https://${info.host or "git.sr.ht"}//${info.owner}/${info.repo}/archive/${info.rev}.tar.gz";
              }
              // lib.hash.from.info info
            );

            inherit (info) rev lastModified;
            shortRev = builtins.substring 0 7 info.rev;
            lastModifiedDate = lib.date.from.modified info.lastModified;
          }
        else
          builtins.throw ''Unsupported input type "${info.type}".'';

      load =
        {
          src,
          replacements ? { },
        }:
        let
          lockFile = "${src}/flake.lock";

          lock = builtins.fromJSON (builtins.readFile lockFile);

          root =
            let
              isGit = builtins.pathExists "${src}/.git";
              isShallow = builtins.pathExists "${src}/.git/shallow";

              result =
                if src ? outPath then
                  src
                else if isGit && !isShallow then
                  let
                    info = builtins.fetchGit src;
                  in
                  if info.rev == "0000000000000000000000000000000000000000" then
                    builtins.removeAttrs info [
                      "rev"
                      "shortRev"
                    ]
                  else
                    info
                else
                  {
                    outPath =
                      if builtins.isPath src then
                        builtins.path {
                          name = "source";
                          path = src;
                        }
                      else
                        src;
                  };
            in
            {
              lastModified = 0;
              lastModifiedDate = lib.date.from.modified 0;
            }
            // result;

          nodes = builtins.mapAttrs (
            name: node:
            let
              info =
                if name == lock.root then
                  root
                else
                  fetch (node.info or { } // builtins.removeAttrs node.locked [ "dir" ]);

              subdir = if name == lock.root then "" else node.locked.dir or "";

              outPath = info + lib.strings.when (subdir != "") "/${subdir}";

              inputs = builtins.mapAttrs (
                name: spec:
                let
                  resolved = resolve spec;
                  input = nodes.${resolve spec};
                in
                if replacements ? ${resolved} then replacements.${resolved} else input
              ) (node.inputs or { });

              resolve = spec: if builtins.isList spec then select lock.root spec else spec;

              select =
                name: path:
                if path == [ ] then
                  name
                else
                  select (resolve lock.nodes.${name}.inputs.${builtins.head path}) (builtins.tail path);

              flake = import "${outPath}/flake.nix";

              outputs = flake.outputs (
                inputs
                // {
                  self = result;
                }
              );

              result =
                outputs
                // info
                // {
                  inherit outPath inputs outputs;
                  sourceInfo = info;
                  _type = "flake";
                };
            in
            if node.flake or true then
              assert builtins.isFunction flake.outputs;
              result
            else
              info
          ) lock.nodes;

          unlocked =
            let
              flake = import "${root}/flake.nix";
              outputs =
                root
                // flake.outputs {
                  self = outputs;
                };
            in
            outputs;

          flake =
            let
              result =
                if !(builtins.pathExists lockFile) then
                  unlocked
                else if lock.version == 4 then
                  # TODO: Get a lockfile with version 4 to test.
                  builtins.throw ''Lock file "${lockFile}" with version "${lock.version}" is not supported.''
                else if lock.version >= 5 && lock.version <= 7 then
                  nodes.${lock.root}
                else
                  builtins.throw ''Lock file "${lockFile}" with version "${lock.version}" is not supported.'';
            in
            result
            // {
              inputs = result.inputs or { } // {
                self = flake;
              };

              _type = "flake";
            };
        in
        flake;
    in
    {
      inherit load fetch lib;
    };

  ensure = value: message: if value then true else builtins.trace message false;

  hasPrefix =
    prefix: value:
    let
      trimmed = builtins.substring 0 (builtins.stringLength prefix) value;
    in
    trimmed == prefix;

  filterAttrs =
    fn: attrs:
    builtins.removeAttrs attrs (
      builtins.filter (name: !(fn name attrs.${name})) (builtins.attrNames attrs)
    );

  scan =
    input:
    let
      contents = builtins.readDir input.src;
    in
    {
      all = contents;
      files = filterAttrs (_name: value: value == "regular") contents;
      directories = filterAttrs (_name: value: value == "directory") contents;
      symlinks = filterAttrs (_name: value: value == "symlink") contents;
    };

  loaders = [
    {
      name = "nilla";
      check =
        input:
        let
          contents = scan input;
        in
        contents.files ? "nilla.nix";
      load =
        input:
        let
          value = import "${input.src}/${input.settings.target or "nilla.nix"}";

          result =
            if input.settings ? extend && input.settings.extend != { } then
              let
                customized = value.extend input.settings.extend;
              in
              customized.config // { inherit (customized) extend; }
            else
              value;
        in
        result;
    }

    {
      name = "nixpkgs";
      check =
        input:
        let
          contents = scan input;
        in
        contents.files ? "default.nix"
        && contents.directories ? "pkgs"
        && contents.directories ? "lib"
        && contents.symlinks ? ".version";
      load =
        input:
        let
        in
        import input.src input.settings;
    }

    {
      name = "flake";
      check =
        input:
        let
          contents = scan input;
        in
        contents.files ? "flake.nix";
      load =
        input:
        flake-compat.load {
          src = builtins.dirOf "${input.src}/${input.settings.target or "flake.nix"}";
          replacements = input.settings.inputs or { };
        };
    }

    {
      name = "sprinkles";
      check =
        input:
        let
          contents = scan input;
        in
        contents.files ? "default.nix"
        && hasPrefix "{ sprinkles ? {} }:\n" (builtins.readFile "${input.src}/default.nix");
      load =
        input:
        let
          value = import "${input.src}/${input.settings.target or "default.nix"}" {
            sprinkles = input.settings.sprinkles or null;
          };
        in
        if value.settings ? override && value.settings.override != { } then
          value.override value.settings.override
        else
          value;
    }

    {
      name = "legacy";
      check =
        input:
        let
          contents = scan input;
        in
        contents.files ? "default.nix";
      load =
        input:
        let
          value = import "${input.src}/${input.settings.target or "default.nix"}";
        in
        if builtins.isFunction value && input.settings ? args then value input.settings.args else value;
    }

    {
      name = "raw";
      check = _: true;
      load = input: input.src;
    }
  ];

  find =
    fn: list:
    if builtins.length list == 0 then
      null
    else if fn (builtins.head list) then
      builtins.head list
    else
      find fn (builtins.tail list);

  select =
    input:
    if input.loader == null then
      find (loader: loader.check input) loaders
    else
      find (loader: loader.name == input.loader) loaders;

  process =
    input:
    let
      loader = select input;
    in
    assert ensure (loader != null) "Could not find loader for ${input.src}";
    assert ensure (builtins.isAttrs input.settings)
      "Settings must be an attribute set, but got ${builtins.typeOf input.settings}.";
    assert ensure (
      input.loader == null || builtins.isString input.loader
    ) "Loader must be a string or null, but got ${builtins.typeOf input.loader}.";
    loader.load input;

  load =
    input:
    if builtins.isAttrs input && input ? src && (input ? settings || input ? loader) then
      process {
        inherit (input) src;
        settings = input.settings or { };
        loader = input.loader or null;
      }
    else
      process {
        inherit (input) src;
        settings = { };
        loader = null;
      };
in
load
