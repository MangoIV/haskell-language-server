{
  description = "haskell-language-server development flake";

  inputs = {
    # Don't use nixpkgs-unstable as aarch64-darwin is currently broken there.
    # Check again, when https://github.com/NixOS/nixpkgs/pull/414242 is resolved.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # For default.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    # sources
    network-wasm.url = "github:haskell-wasm/network/wasi";
    network-wasm.flake = false;
    integer-logarithms.url = "github:mangoiv/integer-logarithms/mangoiv/914";
    integer-logarithms.flake = false;
    algebraic-graphs.url = "github:snowleopard/alga";
    algebraic-graphs.flake = false;
    ghc-exactprint.url = "github:alanz/ghc-exactprint";
    ghc-exactprint.flake = false;
    hiedb.url = "github:mangoiv/hiedb/mangoiv/no-terminal-size";
    hiedb.flake = false;
    direct-sqlite.url = "github:mangoiv/direct-sqlite/mangoiv/wasi";
    direct-sqlite.flake = false;

    # nix
    nixpkgs-wasm.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    ghc-wasm.url = "gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org&ref=debug";
    nix-wasm.url = "github:mangoiv/nix-wasm/mangoiv/914";
    nix-wasm.inputs.nixpkgs.follows = "nixpkgs-wasm";
    nix-wasm.inputs.ghc-wasm-meta.follows= "ghc-wasm";
  };

  outputs =
    inputs@{ nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachSystem
      [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ]
    (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = { allowBroken = true; };
        };

        pythonWithPackages = pkgs.python3.withPackages (ps:
          [ ps.docutils
            ps.myst-parser
            ps.pip
            ps.sphinx
            ps.sphinx-rtd-theme
          ]);

        docs = pkgs.stdenv.mkDerivation {
          name = "hls-docs";
          src = pkgs.lib.sourceFilesBySuffices ./.
            [ ".py" ".rst" ".md" ".png" ".gif" ".svg" ".cabal" ];
          buildInputs = [ pythonWithPackages ];
          buildPhase = ''
            cd docs
            make --makefile=${./docs/Makefile} html BUILDDIR=$out
            '';
          dontInstall = true;
        };

        # Support of GenChangelogs.hs
        gen-hls-changelogs = hpkgs: with pkgs;
          let myGHC = hpkgs.ghcWithPackages (p: with p; [ github ]);
          in pkgs.runCommand "gen-hls-changelogs" {
            passAsFile = [ "text" ];
            preferLocalBuild = true;
            allowSubstitutes = false;
            buildInputs = [ git myGHC ];
          } ''
            dest=$out/bin/gen-hls-changelogs
            mkdir -p $out/bin
            echo "#!${runtimeShell}" >> $dest
            echo "${myGHC}/bin/runghc ${./GenChangelogs.hs}" >> $dest
            chmod +x $dest
          '';

        mkDevShell = hpkgs: with pkgs; mkShell {
          name = "haskell-language-server-dev-ghc${hpkgs.ghc.version}";
          # For binary Haskell tools, we use the default Nixpkgs GHC version.
          # This removes a rebuild with a different GHC version. The drawback of
          # this approach is that our shell may pull two GHC versions in scope.
          buildInputs = [
            # Compiler toolchain
            hpkgs.ghc
            hpkgs.haskell-language-server
            pkgs.haskellPackages.cabal-install
            # Dependencies needed to build some parts of Hackage
            gmp zlib ncurses
            # for compatibility of curl with provided gcc
            curl
            # Changelog tooling
            (gen-hls-changelogs hpkgs)
            # For the documentation
            pythonWithPackages
            (pkgs.haskell.lib.justStaticExecutables (pkgs.haskell.lib.dontCheck pkgs.haskellPackages.opentelemetry-extra))
            capstone
            stylish-haskell
            pre-commit
            ] ++ lib.optionals (!stdenv.isDarwin)
                   [ # tracy has a build problem on macos.
                     tracy
                   ]
              ++ lib.optionals stdenv.isDarwin
              (with darwin.apple_sdk.frameworks; [
                Cocoa
                CoreServices
              ]);
              nativeBuildInputs = [
                pkgs.wasmtime
                pkgs.nodejs_latest
                pkgs.wasm-tools
              ];

          shellHook = ''
            # @guibou: I'm not sure theses lines are needed
            export LD_LIBRARY_PATH=${gmp}/lib:${zlib}/lib:${ncurses}/lib:${capstone}/lib
            export DYLD_LIBRARY_PATH=${gmp}/lib:${zlib}/lib:${ncurses}/lib:${capstone}/lib
            export PATH=$PATH:$HOME/.local/bin

            # Install pre-commit hook
            pre-commit install
          '';
        };

      in {
        # Development shell with only dev tools
        devShells = {
          default = mkDevShell pkgs.haskellPackages;
          shell-ghc96 = mkDevShell pkgs.haskell.packages.ghc96;
          shell-ghc98 = mkDevShell pkgs.haskell.packages.ghc98;
          shell-ghc910 = mkDevShell pkgs.haskell.packages.ghc910;
          shell-ghc912 = mkDevShell pkgs.haskell.packages.ghc912;
        };

        packages = {
          inherit docs;
          ghc = inputs.ghc-wasm.packages.${system}.wasm32-wasi-ghc-9_14;
          ghc-wasm-libdir = pkgs.runCommand "ghc-wasm-libdir" { nativeBuildInputs = [ inputs.ghc-wasm.packages.${system}.all_9_14]; }  ''
            cp -r $(wasm32-wasi-ghc --print-libdir) $out
          '';
          hls-wasm-root = pkgs.runCommand "hls-wasm-root" { nativeBuildInputs = [ inputs.ghc-wasm.packages.${system}.all_9_14 pkgs.zstd ]; } ''
            cp -r $(wasm32-wasi-ghc --print-libdir) ./lib
            echo "cradle:
              direct:
                arguments: []" > ./hie.yaml

            mkdir $out
            tar -acf $out/rootfs.tar.zst ./.
          '';
          hls-linked = pkgs.runCommand "haskell-language-server-linked" { nativeBuildInputs = [inputs.ghc-wasm.packages.${system}.all_9_14]; } ''
            $(wasm32-wasi-ghc --print-libdir)/post-link.mjs -i ${inputs.self.packages.${system}.hls}/bin/haskell-language-server.wasm -o hls.js
            mkdir $out
            mv hls.js $out/hls.js
            cp ${inputs.self.packages.${system}.hls}/bin/haskell-language-server.wasm $out/hls.wasm
          '';
          hls = let
            wasmPkgs = inputs.nix-wasm.legacyPackages.${system};
            inherit (wasmPkgs) lib;
            hlib = wasmPkgs.haskell.lib.compose;
            hspkgs = wasmPkgs.haskellPackages.override (old: {
              overrides = lib.composeManyExtensions [ old.overrides
                (hself: hsuper: with hlib; {
                  # source overrides
                  shake = null;
                  hls-plugin-api = disableCabalFlag "use-fingertree"
                    (hself.callCabal2nixWithOptions "hls-plugin-api" ./hls-plugin-api "-f-use-fingertree" {});
                  ghcide = hself.callCabal2nix "ghcide" ./ghcide {};
                  zlib = addBuildDepends [hself.zlib-clib] hsuper.zlib;
                  haskell-language-server =
                    ( dontBenchmark
                    ( dontCheck
                    ( enableCabalFlag "dynamic"
                    ( disableCabalFlag "fourmolu"
                    ( disableCabalFlag "cabal"
                    ( disableCabalFlag "ormolu"
                    ( disableCabalFlag "stylish-haskell"
                    ( disableCabalFlag "stan"
                    ( disableCabalFlag "hlint"
                    ( hself.callCabal2nixWithOptions "haskell-language-server" ./.
                        "-f-fourmolu -f-cabal -f-ormolu -f-stan -f-stylishHaskell -f-hlint" {}
                    ))))))))));
                  direct-sqlite = hself.callCabal2nix "direct-sqlite" inputs.direct-sqlite {};
                  ghc-exactprint = hsuper.ghc-exactprint.overrideAttrs {src = inputs.ghc-exactprint; };
                  integer-logarithms = hself.callCabal2nix "integer-logarithms" inputs.integer-logarithms {};
                  data-default = doJailbreak hsuper.data-default;
                  co-log-core = doJailbreak hsuper.co-log-core;
                  indexed-traversable = doJailbreak hsuper.indexed-traversable;
                  tagged = doJailbreak hsuper.tagged;
                  clay = doJailbreak hsuper.clay;
                  assoc = doJailbreak hsuper.assoc;
                  some = doJailbreak hsuper.some;
                  hiedb = disableCabalFlag "terminal"
                    (hself.callCabal2nixWithOptions "hiedb" inputs.hiedb "-f-terminal" {});
                  hie-compat = doJailbreak hsuper.hie-compat;
                  implicit-hie = disableCabalFlag "executable" hsuper.implicit-hie;

                  ghc-trace-events = doJailbreak hsuper.ghc-trace-events;
                  algebraic-graphs = doJailbreak (hsuper.algebraic-graphs.overrideAttrs { src = inputs.algebraic-graphs; });
                  ghc-lib-parser = doJailbreak (hself.callHackageDirect {pkg = "ghc-lib-parser"; ver = "9.14.1.20251220"; sha256 = "sha256-+ZtPe43asG2EjuRpuLU0r3Q3H3LqkkLRJQ28Y/o9nKM="; } {});
                  ghc-lib-parser-ex = doJailbreak (hself.callHackageDirect {pkg = "ghc-lib-parser-ex"; ver = "9.14.1.20251220"; sha256 = "sha256-JovZ4M0NQ3VxaIvRe0Od+Yi1F/fEd4ac12piEDVVa7o="; } {});
                  network = hsuper.network.overrideAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [wasmPkgs.autoreconfHook];
                    src = inputs.network-wasm;
                  });
                  parallel = doJailbreak hsuper.parallel;
                  th-compat = doJailbreak hsuper.th-compat;
                  th-abstraction = doJailbreak hsuper.th-abstraction;
              })];
            });
          in hspkgs.haskell-language-server;
        };
      });

  nixConfig = {
  };
}
