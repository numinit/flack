{
  lib,
  flack,
  self,
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
    splitString
    ;

  inherit (lib.lists)
    isList
    head
    length
    filter
    all
    sublist
    flatten
    singleton
    ;

  inherit (lib.attrsets) listToAttrs nameValuePair mapAttrsToList;

  packagesUnder = import ./eval-packages.nix {
    inherit lib;
  };

  getFrontend = req: path: "${self.inputs.nixos-search.packages.${req.system}.frontend}${path}";
in
{
  route = rec {
    GET."/" = req: req.res 200 { } (getFrontend req "/index.html");
    GET."/packages" = GET."/";
    GET."/:...path" = req: req.res 200 { } (getFrontend req req.path);
  };

  mount = {
    "/backend" = {
      route.POST."/:version/_search" =
        req:
        let
          normalizeQuery = query: toLower (removePrefix "*" (removeSuffix "*" query));

          coerceInt = val: if isInt val then val else 0;
          coerceString = val: if isString val then val else null;
          coerceList = val: if isList val then val else [ ];

          query = map normalizeQuery (
            flatten (
              map (
                must:
                filter (x: x != null) (
                  map (query: coerceString (query.wildcard.package_attr_name.value or null)) (
                    coerceList (must.dis_max.queries or [ ])
                  )
                )
              ) (coerceList (req.body.query.bool.must or [ ]))
            )
          );
          size = max 0 (min 50 (coerceInt (req.body.size or 50)));
          from = max 0 (coerceInt (req.body.from or 0));

          packageSet =
            version:
            let
              packageSetMatch = match "^.+-nixos-(.+)$" version;
            in
            if version == null || packageSetMatch == null then
              "nixpkgs"
            else if head packageSetMatch == "25.05" then
              "nixpkgs-25_05"
            else
              "nixpkgs";

          pkgs = self.inputs.${packageSet (req.params.version or null)}.legacyPackages.${req.system};
          pkgsThatEval = packagesUnder [ ] (_: _: true) pkgs;
          matches = filter (x: all (q: hasInfix q (toLower x.attrPath)) query) pkgsThatEval;
          resultsList = map (x: nameValuePair x.attrPath x.package) matches;
          results = listToAttrs resultsList;

          toMaintainer = maintainer: {
            name = maintainer.name or "";
            github = maintainer.github or "";
            email = maintainer.email or "";
          };

          toPosition =
            position:
            let
              matchResult = match "^/nix/store/[^/]+/(.+)$" position;
            in
            if position == null || matchResult == null then null else head matchResult;

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

          mkSource =
            {
              name,
              packageName,
              version,
              package,
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
              package_mainProgram = package.meta.mainProgram or null;
              package_license = map (x: {
                fullName = x.fullName or x.shortName or "";
                url = x.url or null;
              }) (toLicenses (package.meta.license or [ ]));
              package_license_set = map (x: x.fullName) (toLicenses (package.meta.license or [ ]));
              package_maintainers = map toMaintainer (package.meta.maintainers or [ ]);
              package_maintainers_set = map (x: x.name) (package.meta.maintainers or [ ]);
              package_teams = map (x: {
                members = map toMaintainer x.members;
                shortName = x.shortName or "";
                scope = x.scope or null;
                githubTeams = x.githubTeams or [ ];
              }) (package.meta.teams or [ ]);
              package_teams_set = map (x: x.shortName) (package.meta.teams or [ ]);
              package_description = package.meta.description or "";
              package_longDescription = package.meta.longDescription or "";
              package_hydra = null; # XXX where does this come from?
              package_system = package.system or null;
              package_homepage = package.meta.homepage or "";
              package_position = toPosition (package.meta.position or null);
            };

          mkHit =
            name: value:
            let
              packageName = value.pname or value.name or name;
              version =
                let
                  version' = value.version or "";
                in
                if version' == null then "" else version';
            in
            rec {
              _index = "flack";
              _type = "_doc";
              _id = req.id;
              _score = 1.0;
              _source = mkSource {
                inherit name packageName version;
                package = value;
              };
              _sort = [
                _score
                packageName
                version
              ];
              matched_queries = [ "filter_packages" ];
            };

          mkBuckets = total: buckets: {
            doc_count_error_upper_bound = 0;
            sum_other_doc_count = total;
            inherit buckets;
          };
        in
        req.res 200 {
          took = 1;
          timed_out = false;
          _shards = {
            total = 1;
            successful = 1;
            skipped = 0;
            failed = 0;
          };
          hits = {
            total = {
              value = length resultsList;
              relation = "eq";
            };
            max_score = null;
            hits = sublist from size (mapAttrsToList mkHit results);
          };
          aggregations = {
            all = {
              doc_count = length pkgsThatEval;
              package_attr_set = mkBuckets 0 [ ];
              package_maintainers_set = mkBuckets 0 [ ];
              package_teams_set = mkBuckets 0 [ ];
              package_platforms = mkBuckets 0 [ ];
              package_license_set = mkBuckets 0 [ ];
            };
            package_attr_set = mkBuckets 0 [ ];
            package_maintainers_set = mkBuckets 0 [ ];
            package_teams_set = mkBuckets 0 [ ];
            package_platforms = mkBuckets 0 [ ];
            package_license_set = mkBuckets 0 [ ];
          };
        };
    };
  };
}
