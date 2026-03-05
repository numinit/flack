{
  lib,
  flack,
  inputs,
  ...
}:

let
  name = "presentation";

  inherit (flack.lib.paths) joinPathToIndex;

  inherit (lib.attrsets) mapAttrsToList;

  inherit (inputs) htnl nixpkgs;

  inherit (htnl.lib) serialize;
  h = htnl.lib.polymorphic.element;

  mkSlideHtml =
    name: value: req:
    nixpkgs.legacyPackages.${req.system}.writeTextDir "www/${name}.html" (serialize value);

  mkSlidesHtml =
    slides: req:
    nixpkgs.legacyPackages.${req.system}.symlinkJoin {
      name = "slides";
      paths = mapAttrsToList (name: value: mkSlideHtml name value req) slides;
      postBuild = ''
        ln -s ${./slide.css} $out/www/style.css
        ln -s ${./script.js} $out/www/script.js
      '';
    };

  mkSlide =
    body:
    h "html" [
      (h "head" [
        (h "title" "Flack the Planet!")
        (h "link" {
          rel = "stylesheet";
          href = "/talk/style.css";
        })
        (h "script" {
          type = "text/javascript";
          src = "/talk/script.js";
        } "")
      ])
      (h "body" body)
    ];

  presentation = mkSlidesHtml {
    index = mkSlide [
      (h "article" [
        (h "header" [
          (h "h1" "Flack the Planet")
          (h "h2" "The web framework no one asked for.")
          (h "h3" "mjones (@numinit)")
          (h "h4" (h "a" { href = "https://github.com/numinit/flack"; } "https://github.com/numinit/flack"))
        ])
        (h "section" [
          (h "h1" "What is this?")
          (h "ul" [
            (h "li" "A tech demo?")
            (h "li" "An elaborate joke?")
            (h "li" "Performance art?")
            (h "li" "An exploration into the weird and wonderful things Nix can do?")
            (h "li" "You decide.")
          ])
        ])
        (h "section" [
          (h "h1" "A history of web frameworks")
          (h "ul" [
            (h "li" "1990s to early to mid-2000s: CGI (RFC 3875)")
          ])
          (h "pre" ''
            Network Working Group                                        D. Robinson
            Request for Comments: 3875                                       K. Coar
            Category: Informational                   The Apache Software Foundation
                                                                        October 2004


                         The Common Gateway Interface (CGI) Version 1.1
          '')
        ])
        (
          let
            style = "height: 50px";
            iframe =
              q: o:
              (h "iframe" (
                {
                  src = "/cgi-bin/now.cgi${q}";
                  inherit style;
                }
                // o
              ) "");
            lol1 = h "section" [
              (h "h1" "So, how did it work?")
              (h "ul" [
                (h "li" "Your web server executes a script that's passed environment variables")
                (iframe "?src=true" { })
              ])
              (h "ul" [
                (h "li" "You include it in an iframe")
                (h "li" [
                  "Such as: "
                  (h "pre" (serialize (iframe "" { })))
                ])
                (h "li" "And it appears like this:")
                (iframe "" { })
              ])
            ];

            lol2 = h "section" [
              (h "h1" "Problems")
              (h "ul" [
                (h "li" "Maybe shell commands are fast")
                (iframe "?src=true" { })
                (iframe "?time=true" { style = "height: 150px"; })
                (h "li" "But a whole interpreter is slow!")
                (iframe "?src=true&nix=true" { })
                (iframe "?time=true&nix=true" { style = "height: 150px"; })
              ])
            ];
          in
          [
            lol1
            lol2
          ]
        )
      ])
      (h "article" [
        (h "header" [
          (h "h1" "FastCGI and reverse app proxies")
        ])
        (h "section" [
          (h "h1" "How this works is pretty simple")
          (h "h2" "This got more popular in the late 2000s and 2010s")
          (h "ul" [
            (h "li" "Load your app beforehand")
            (h "li" [
              "Have the app render the result on the fly using a "
              (h "strong" "persistent")
              " process"
            ])
            (h "li" [
              "For instance: "
              (h "pre" "GET /api/now")
              (h "pre" { id = "now"; } "wait for it")
            ])
            (h "li" "HTML can be pre-rendered and served as static files")
          ])
        ])
        (
          let
            lol =
              extra:
              h "section" [
                (h "h1" "The rise of the webapp")
                (h "h2" "\"Everyone (dis)liked that\"")
                (h "ul" (
                  [
                    (h "li" "Rails (Ruby; 2004)")
                    (h "li" "Django (Python; 2005)")
                    (h "li" "Rack and Sinatra (Ruby; 2007)")
                    (h "li" "Flask (Python; 2010)")
                    (h "li" "Express (Node.js; 2010)")
                  ]
                  ++ extra
                ))
              ];
          in
          [
            (lol [ ])
            (lol [ (h "li" (h "strong" "Nixpkgs (Nix; 2003)")) ])
          ]
        )
      ])
      (h "article" [
        (h "header" [
          (h "h1" "What would a persistent Nix evaluator look like?")
        ])
        (h "section" [
          (h "h1" "Enter Flack")
          (h "h2" "Because naming your webapp framework after a singer is what the cool kids do")
          (h "em" "[Roberta Flack] produced the single and her 1975 album of the same name under the pseudonym \"Rubina Flake\"")
          (h "img" {
            src = "https://upload.wikimedia.org/wikipedia/commons/thumb/3/32/Roberta_Flack_1976.jpg/500px-Roberta_Flack_1976.jpg";
          })
        ])
        (h "section" [
          (h "h1" "What does it look like?")
          (h "h2" [
            "I hope you like "
            (h "a" { href = "https://github.com/molybdenumsoftware/htnl"; } "HTNL")
            " and the module system"
          ])
          (
            let
              lol = ''
                { lib, flack, inputs, ... }:

                let
                  # ...

                  mkSlide = body:
                    h "html" [
                      (h "head" [
                        (h "title" "Flack the Planet!")
                      ])
                      (h "body" body)
                    ];

                  presentation = mkSlidesHtml {
                    index = mkSlide [
                      (h "article" [
                        ...
                      ])
                    ];
                  };

                  servePresentation = req:
                    "''${presentation req}/www/''${joinPathToIndex (req.params.path or ["/"])}";
                in
                {
                  route = {
                    GET."/" = req: req.res 200 { } (servePresentation req);
                    GET."/talk/:...path" = req: req.res 200 { } (servePresentation req);
                  };
                }
              '';
            in
            (h "pre" lol)
          )
        ])
        (h "section" [
          (h "h1" "Middlewares, mountpoints, and routes")
          (h "h2" [ "Rejected name: Nixpress" ])
          (
            let
              lol = ''
                use = {
                  /*
                    This is a middleware.
                    If X-Auth-Token isn't "supersecret" then it'll return a 401 for all paths under /foo.
                    Obviously there is a timing sidechannel here, don't actually do this.
                  */
                  "/foo" =
                    req: if req.get "X-Auth-Token" != "supersecret" then req.res 401 { } "Unauthorized" else req;
                };
                route = {
                  /*
                    This is a route.
                    bar is available in req.params.
                    Note the auth token above!
                    `curl -H 'X-Auth-Token: supersecret' http://localhost:2019/foo/myBar`
                  */
                  GET."/foo/:...bar" =
                    req:
                    req.res 200 { "X-My-Header" = "value"; } {
                      inherit (req) pathComponents;
                      inherit (req.params) bar;
                    };
                };
              '';
            in
            (h "pre" lol)
          )
        ])
      ])
      (h "article" [
        (h "header" [
          (h "h1" "Using the nixops4 Rust bindings")
        ])
        (h "section" [
          (h "h1" "https://github.com/nixops4/nix-bindings-rust")
          (h "ul" [
            (h "li" "Shoutout to Robert Hensing and John Ericson for getting us off Perl and onto Rust")
            (h "li" [
              "The Rust bindings are "
              (h "strong" "usable today")
            ])
            (h "li" [ "Good enough to render this slide deck to ${placeholder "out"}*" ])
            (h "li" "* With one caveat")
          ])
        ])
        (h "section" [
          (h "h1" "Multithreading")
          (h "ul" [
            (h "li" [
              "Nix historically has been a single threaded system operable by one user at a time, "
              (h "strong" "but all is not lost.")
            ])
            (h "li" "The Boehm GC is thread-safe!")
          ])
          (h "h2" "Just do this:")
          (h "pre" ''
            nix_bindings_expr::eval_state::gc_register_my_thread()
          '')
          (h "h2" [
            "Cloning values using the Rust bindings "
            (h "strong" "atomically modifies their refcount")
          ])
          (h "pre" ''
            /// Evals a string and then calls the result.
            fn call_fn(func: &str, st: &mut EvalState, value: &Value, dir: &str) -> std::io::Result<Value> {
                let func_val = st
                    .eval_from_string(func, dir)
                    .map_err(std::io::Error::other)?;
                st.call(func_val, value.clone()) // not an actual copy!
                    .map_err(std::io::Error::other)
            }
          '')
        ])
        (h "section" [
          (h "h1" "Has to be a catch, right?")
          (h "ul" [
            (h "li" "EvalState will be:")
            (h "ul" [
              (h "li" "thread unsafe in NixOS/nix")
              (h "li" [
                "thread safe in DeterminateSystems/nix-src due to "
                (h "strong" "parallel eval")
              ])
            ])
          ])
          (h "pre" ''
            /// These need to be added if you want to use EvalState and Value in multiple threads
            unsafe impl Send for EvalState { }
            unsafe impl Send for Value { }

            /// Gets a new EvalState for the specified store.
            fn init_get_state(
                store: Store,
            ) -> std::io::Result<(EvalState, ThreadRegistrationGuard)> {
                let gc_guard = init_get_gc_guard()?;

                let mut state_builder = nix_bindings_expr::eval_state::EvalStateBuilder::new(store)
                    .map_err(std::io::Error::other)?;

                let state = state_builder.build().map_err(std::io::Error::other)?;

                Ok((state, gc_guard))
              }
          '')
        ])
        (h "section" [
          (h "h1" "What about the store?")
          (h "ul" [
            (h "li" "It's threadsafe, but set max-connections to something high because the default is 1")
            (h "pre" ''
              let cores = match std::thread::available_parallelism() {
                  Ok(val) => val,
                  Err(err) => {
                      warn!("Error getting parallelism, defaulting to 1: {:?}", err);
                      NonZero::new(1).unwrap()
                  }
              };

              let store_uri = url::Url::parse_with_params(
                  args.store.as_str(),
                  &[(
                      "max-connections",
                      format!("{}", cores).as_str(),
                  )],
              )
              .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;

              let store = nix_bindings_store::store::Store::open(Some(store_uri.to_string().as_str()), [])
                  .map_err(|e| std::io::Error::new(std::io::ErrorKind::ConnectionRefused, e))?;
            '')
          ])
        ])
      ])
      (h "article" [
        (h "header" [
          (h "h1" "So, we need Determinate Nix... what else can we turn on by default?")
        ])
        (h "section" [
          (h "h1" "How you can make your own Nix frontend")
          (h "ul" [
            (h "li" [(h "strong" "Parallel eval: ") "preload and bundle the app by forcing every defined route"])
            (h "li" [(h "strong" "Pipe operator: ") "everyone should just use it"])
            (h "li" [(h "strong" "Flakes: ") "expose `flack.apps.default` in your flake to serve it"])
            (h "li" "Caveat about the settings API: https://github.com/NixOS/nix/pull/14917")
          ])
        ])
      ])
      (h "article" [
        (h "header" [
          (h "h1" "Can we use it to write things where we'd ordinarily use nix repl?")
          (h "h2" (h "a" { href = "https://search.flack.dev"; target = "_blank"; } "Hmmmm... 🤔"))
        ])
      ])
    ];
  };

  servePresentation = req: "${presentation req}/www/${joinPathToIndex (req.params.path or [ "/" ])}";
in
{
  inherit name;

  mount = {
    "/api" = {
      route.GET = {
        "/now" = req: req.res 200 { } { now = req.timestamp; };
      };
    };

    "/cgi-bin" =
      let
        mkSrc =
          fn: req:
          let
            inherit (nixpkgs.legacyPackages.${req.system}) writeText;
            cmd = fn req;
            cmd' = if req.query ? src then writeText "${cmd.name}.src" cmd.buildCommand else cmd;
          in
          cmd';

        getNowDate = mkSrc (
          req:
          let
            inherit (inputs.nixpkgs.legacyPackages.${req.system}) runCommand time;
          in
          runCommand "now.txt" { inherit (req) id; } ''
            ${lib.optionalString (req.query ? time) "${lib.getExe time} -p "}date &>$out
          ''
        );

        getNowNix = mkSrc (
          req:
          let
            inherit (inputs.nixpkgs.legacyPackages.${req.system}) runCommand nix time;
          in
          runCommand "now.txt"
            {
              inherit (req) id;
              inherit nix;
            }
            ''
              NIX_STATE_DIR=$(pwd) ${
                lib.optionalString (req.query ? time) "${lib.getExe time} -p "
              }$nix/bin/nix-instantiate --eval --expr builtins.currentTime &>$out
            ''
        );

        getNow = req: if req.query ? nix then getNowNix req else getNowDate req;
      in
      {
        route.GET = {
          "/now.cgi" =
            req:
            # We can serve a derivation directly, Flack figures it out.
            req.res 200 { "Content-Type" = "text/html"; } (
              serialize (
                mkSlide (
                  (lib.optionals (!(req.query ? src)) [
                    (h "meta" {
                      "http-equiv" = "refresh";
                      "content" = "1";
                    })
                  ])
                  ++ [ (h "h1" (h "pre" (lib.readFile (getNow req)))) ]
                )
              )
            );
        };
      };
  };

  route = {
    GET."/" = req: req.res 200 { } (servePresentation req);
    GET."/talk/:...path" = req: req.res 200 { } (servePresentation req);
  };
}
