{
  lib,
  flack,
  inputs',
  ...
}:

let
  inherit (lib.trivial)
    isInt
    max
    min
    ;

  inherit (lib.strings)
    isString
    removePrefix
    removeSuffix
    toLower
    hasInfix
    match
    escapeXML
    splitString
    ;

  inherit (lib.lists)
    isList
    elemAt
    head
    length
    concatMap
    filter
    any
    sublist
    flatten
    findFirst
    singleton
    ;

  inherit (lib.attrsets)
    optionalAttrs
    attrsToList
    ;

  inherit (flack.lib.paths) joinPathToIndex;

  getFrontend =
    req: path: "${inputs'.nixos-search.packages.${req.system}.frontend}/${joinPathToIndex path}";
in
{
  route = rec {
    # These allow us to serve a static site with Flack.
    # In all cases, the nixos-search frontend is built on-demand and a path under it is served.
    GET."/" = req: req.res 200 { } (getFrontend req [ "/" ]);
    GET."/packages" = GET."/";
    GET."/options" = GET."/";
    GET."/flakes" = GET."/";
    GET."/:...path" = req: req.res 200 { } (getFrontend req req.params.path);
  };

  mount = {
    "/backend" = {
      # This implements package search using a hacky subset of the Elastic API.
      route.POST."/:version/_search" =
        req:
        let
          coerceInt = val: if isInt val then val else 0;
          coerceString = val: if isString val then val else null;
          coerceList = val: if isList val then val else [ ];

          # Pull all the filters out of the search query.
          filters = filter (x: x != null) (
            map (x: coerceString (x.term.type._name or null)) (coerceList (req.body.query.bool.filter or [ ]))
          );

          # True if we are searching packages.
          isPackageSearch = findFirst (x: x == "filter_packages") null filters != null;

          # Likewise for options.
          isOptionSearch = findFirst (x: x == "filter_options") null filters != null;

          # The search parameter for the current search mode.
          searchParam =
            if isPackageSearch then
              "package_attr_name"
            else if isOptionSearch then
              "option_name"
            else
              # default to package search
              "package_attr_name";

          # Pull all of the must parameters out of the search query.
          normalizeQuery = query: toLower (removePrefix "*" (removeSuffix "*" query));
          musts = map normalizeQuery (
            flatten (
              map (
                must:
                filter (x: x != null) (
                  map (query: coerceString (query.wildcard.${searchParam}.value or null)) (
                    coerceList (must.dis_max.queries or [ ])
                  )
                )
              ) (coerceList (req.body.query.bool.must or [ ]))
            )
          );

          # Parse pagination params.
          size = max 0 (min 50 (coerceInt (req.body.size or 50)));
          from = max 0 (coerceInt (req.body.from or 0));

          # Select the package set.
          packageSet =
            version:
            let
              packageSetMatch = match "^.+-(nixos-(.+)|group-manual)$" version;
            in
            if version == null || packageSetMatch == null then
              "nixpkgs"
            else if head packageSetMatch == "group-manual" then
              "flake"
            else if match "^[0-9]{2}\\.[0-9]{2}$" (elemAt packageSetMatch 1) != null then
              "stable"
            else
              "nixpkgs";

          # Pick the package set.
          thePackageSet = packageSet (req.params.version or null);
          isFlakeSearch = thePackageSet == "flake";

          # Figure out the nixpkgs to use from the package set.
          theNixpkgs =
            {
              nixpkgs = inputs'.nixpkgs;
              stable = inputs'.nixpkgs-stable;

              # Use unstable when evaluating flakes.
              flake = inputs'.nixpkgs;
            }
            .${thePackageSet};

          # Eval the things we need to search.
          inherit
            (import ./eval-packages.nix {
              inherit (theNixpkgs) lib;
              pkgs = theNixpkgs.legacyPackages.${req.system};
            })
            packagesUnder
            flakeOptionsUnder
            nixosOptionsUnder
            ;

          # Creates extra data depending on whether we are searching a flake or not.
          mkExtra =
            name: flake:
            {
              inherit name;
            }
            // optionalAttrs isFlakeSearch {
              inherit flake;
            };

          # All packages we are searching for.
          packageResultsFor =
            flakes:
            concatMap (
              { name, value }:
              if value ? legacyPackages.${req.system} then
                packagesUnder [ ] (_: _: true) (mkExtra name value) value.legacyPackages.${req.system}
              else
                [ ]
            ) (attrsToList flakes);

          # All options we are searching for.
          optionResultsFor =
            flakes:
            concatMap (
              { name, value }:
              if name == "nixpkgs" || match "^nixpkgs-[0-9]+" name != null then
                nixosOptionsUnder {
                  nixpkgs = value;
                  extra = mkExtra name value;
                }
              else
                flakeOptionsUnder {
                  nixpkgs = theNixpkgs;
                  flake = value;
                  resolved = value;
                  extra = mkExtra name value;
                }
            ) (attrsToList flakes);

          # Results from the above.
          allResults =
            let
              selectedFlakes = if isFlakeSearch then inputs' else { nixpkgs = theNixpkgs; };
            in
            if isPackageSearch then
              packageResultsFor selectedFlakes
            else if isOptionSearch then
              optionResultsFor selectedFlakes
            else
              throw "neither package nor option search was selected";

          # Compute matches using a pretty rudimentary algorithm.
          # TODO: extend to other package sets, and use a trigram index for sub-O(n).
          matches = filter (x: any (q: hasInfix q (toLower x.name)) musts) allResults;

          # These are useful for various search helpers
          emptyToNull = x: if x == "" then null else x;
          nullToEmpty = x: if x == null then "" else x;

          # Converts a nixpkgs maintainer to JSON.
          toMaintainer = maintainer: {
            name = maintainer.name or "";
            github = emptyToNull (maintainer.github or "");
            email = emptyToNull (maintainer.email or "");
          };

          # Creates the derivation position by stripping the store prefix.
          toPosition =
            position:
            let
              matchResult = match "^/nix/store/[^/]+/(.+)$" position;
            in
            if position == null || matchResult == null then null else head matchResult;

          # Creates a license list.
          toLicenses =
            licenses:
            if isList licenses then
              licenses
            else if isString licenses then
              singleton rec {
                shortName = licenses;
                fullName = shortName;
              }
            else
              singleton licenses;

          # Creates a flake source.
          mkFlakeSource =
            {
              name,
              flake,
              ...
            }:
            rec {
              flake_name = name;
              flake_description = emptyToNull (flake.description or "");
              revision = flake.rev or flake.dirtyRev or null;
              flake_source =
                if flake ? url && builtins ? parseFlakeRef then builtins.parseFlakeRef flake.url else null;
              flake_resolved = flake_source;
            };

          # Creates a package source.
          mkPackageSource =
            {
              name,
              packageName,
              version,
              package,
              flake ? { },
            }:
            {
              type = "package";
              package_attr_name = name;
              package_attr_set = head (splitString "." name);
              package_pname = packageName;
              package_pversion = version;
              package_platforms = filter isString (package.meta.platforms or [ ]);
              package_outputs = package.outputs or [ ];
              package_default_output = package.outputName or "out";
              package_programs = [ ]; # XXX needs sqlite db from hydra.
              package_mainProgram = emptyToNull (package.meta.mainProgram or null);
              package_license = map (x: {
                fullName = x.fullName or x.shortName or "";
                url = x.url or null;
              }) (toLicenses (package.meta.license or [ ]));
              package_license_set = map (x: x.fullName) (toLicenses (package.meta.license or [ ]));
              package_maintainers = map toMaintainer (package.meta.maintainers or [ ]);
              package_maintainers_set = map (x: x.name) (package.meta.maintainers or [ ]);
              package_teams = map (x: {
                members = map toMaintainer x.members;
                shortName = emptyToNull (x.shortName or "");
                scope = emptyToNull (x.scope or null);
                githubTeams = x.githubTeams or [ ];
              }) (package.meta.teams or [ ]);
              package_teams_set = map (x: x.shortName) (package.meta.teams or [ ]);
              package_description = emptyToNull (package.meta.description or "");
              package_longDescription = emptyToNull (package.meta.longDescription or "");
              package_hydra = null; # XXX where does this come from?
              package_system = nullToEmpty (package.system or null);
              package_homepage = package.meta.homepage or "";
              package_position = toPosition (package.meta.position or null);
            }
            // optionalAttrs (flake ? flake) (mkFlakeSource flake);

          # Creates an option source.
          mkOptionSource =
            {
              name,
              option,
              flake ? option.extra or { },
            }:
            {
              type = "option";
              option_name = name;
              option_source = head (option.declarations or [ "unknown" ]);
              # XXX: This needs Markdown rendering but we can get away with the ugly thing for now.
              option_description =
                let
                  description = emptyToNull (option.description or "");
                in
                if description == null then null else "<rendered-html>${escapeXML description}</rendered-html>";
              option_type = option.type or "";
              option_default = emptyToNull (toString (option.default.text or ""));
              option_example = emptyToNull (toString (option.example.text or ""));
              option_flake = option.modulePath or null;
            }
            // optionalAttrs (flake ? flake) (mkFlakeSource flake);

          # Creates an arbitrary Elasticsearch document.
          mkDoc =
            { source, sort }:
            rec {
              _index = "flack";
              _type = "_doc";
              _id = req.id;
              _score = 1.0;
              _source = source;
              _sort = singleton _score ++ sort;
              matched_queries = filters;
            };

          # Creates a "hit" for a package.
          mkPackageHit =
            {
              name,
              value,
              extra ? { },
              ...
            }:
            let
              packageName = value.pname or value.name or name;
              version =
                let
                  version' = value.version or "";
                in
                if version' == null then "" else version';
            in
            mkDoc {
              source = mkPackageSource (
                {
                  inherit name packageName version;
                  package = value;
                }
                // optionalAttrs (extra ? flake) {
                  flake = extra;
                }
              );
              sort = [
                packageName
                version
              ];
            };

          # Creates a hit for an option.
          mkOptionHit =
            {
              name,
              value,
              extra ? { },
              ...
            }:
            mkDoc {
              source = mkOptionSource (
                {
                  inherit name;
                  option = value;
                }
                // optionalAttrs (extra ? flake) {
                  flake = extra;
                }
              );
              sort = [ name ];
            };

          # Creates a hit for the current search term.
          mkHit = if isPackageSearch then mkPackageHit else mkOptionHit;

          # Creates a buckets JSON.
          mkBuckets = total: buckets: {
            doc_count_error_upper_bound = 0;
            sum_other_doc_count = total;
            inherit buckets;
          };

          # Creates aggregations.
          aggregations =
            all:
            optionalAttrs isPackageSearch {
              package_attr_set = mkBuckets 0 [ ];
              package_maintainers_set = mkBuckets 0 [ ];
              package_teams_set = mkBuckets 0 [ ];
              package_platforms = mkBuckets 0 [ ];
              package_license_set = mkBuckets 0 [ ];
            };
        in
        req.res 200 {
          took = 1;
          timed_out = false;

          # Not sure what to put here... one shard, zero failed sounds reasonable.
          _shards = {
            total = 1;
            successful = 1;
            skipped = 0;
            failed = 0;
          };

          hits = {
            total = {
              value = length matches;
              relation = "eq";
            };
            max_score = null;

            # Paginate the matched packages.
            hits = sublist from size (map mkHit matches);
          };

          # TODO: implement aggregations.
          aggregations = {
            all = {
              doc_count = length allResults;
            }
            // aggregations true;
          }
          // aggregations false;
        };
    };
  };
}
