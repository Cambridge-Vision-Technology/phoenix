{
  description = "Native Phoenix packaging";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/31ecbaca1bdefa45dffc409f0250bd8039ea0010";
    tooling-nixpkgs.url = "github:NixOS/nixpkgs/3497aa5c9457a9d88d71fa93a4a8368816fbeeba";
    purs-nix = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/purs-nix?rev=12a7bcf1b002ac080c3187eec641332d64b5c2c7&lfs=1";
      inputs.nixpkgs.follows = "tooling-nixpkgs";
    };
    platform = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/purescript-platform?rev=fafbb882c312c1d8b0854512d9a821039775d8c0&lfs=1";
      flake = false;
    };
    purescript-whine = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/purescript-whine?rev=fea51b680d750d304eb0d16e57aeea1c85012111&lfs=1";
      inputs.nixpkgs.follows = "tooling-nixpkgs";
      inputs.purs-nix.follows = "purs-nix";
    };
  };

  outputs =
    inputs:
    let
      system = "x86_64-linux";
      pkgs = import inputs.nixpkgs { inherit system; };
      toolingPkgs = import inputs.tooling-nixpkgs { inherit system; };
      fs = pkgs.lib.fileset;
      inventory = builtins.fromJSON (builtins.readFile ./nix/frontend-inputs.json);
      toolInputs = builtins.fromJSON (builtins.readFile ./nix/frontend-tool-inputs.json);
      source =
        paths:
        fs.toSource {
          root = ./.;
          fileset = fs.unions (map (path: ./. + "/${path}") paths);
        };
      platformRoot = /. + builtins.unsafeDiscardStringContext inputs.platform.outPath;
      platformSource =
        paths:
        fs.toSource {
          root = platformRoot;
          fileset = fs.unions (map (path: platformRoot + "/${path}") paths);
        };
      purs = inputs.purs-nix {
        inherit system;
        pkgs = toolingPkgs;
      };
      toolDependencies = [
        "prelude"
        "effect"
        "arrays"
        "either"
        "maybe"
        "nullable"
        "exceptions"
        "strings"
        "foldable-traversable"
        "argonaut-codecs"
        "node-process"
      ];
      tooling = builtins.mapAttrs (
        _: entry:
        purs.purs {
          srcs = [
            "${source entry.sources}/tools"
            "${platformSource entry.platform}/tools"
          ];
          dependencies = entry.dependencies;
        }
      ) toolInputs;
      tools = builtins.mapAttrs (
        name: project: project.script { module = toolInputs.${name}.module; }
      ) tooling;
      platformInventory = builtins.fromJSON (builtins.readFile (inputs.platform + "/nix/inputs.json"));
      inventoryProject = purs.purs {
        srcs = [ "${platformSource platformInventory.inventoryRunner}/tools" ];
        dependencies = toolDependencies ++ [
          "foreign-object"
          "ordered-collections"
          "node-path"
        ];
      };
      inventoryTool = inventoryProject.script { module = "Build.Inventory"; };
      checkRunner =
        (purs.purs {
          srcs = [ "${platformSource platformInventory.checkRunner}/tools" ];
          dependencies = [
            "prelude"
            "effect"
            "arrays"
            "maybe"
            "exceptions"
            "node-process"
          ];
        }).script
          { module = "Build.CheckRunner"; };
      toolChecks = builtins.mapAttrs (
        name: project:
        let
          entry = toolInputs.${name};
          context = toolingPkgs.writeText "frontend-${name}-inventory.json" (
            builtins.toJSON {
              inherit name;
              backend = "node";
              compiler = "${purs.purescript}/bin/purs";
              compilation = project.output { codegen = "corefn,js"; };
              roots = [ entry.module ];
              groups = [
                {
                  root = source entry.sources;
                  files = entry.sources;
                }
                {
                  root = platformSource entry.platform;
                  files = entry.platform;
                }
              ];
              dependencies = project.dependencies;
            }
          );
        in
        toolingPkgs.runCommand "phoenix-frontend-${name}-inventory" { } ''
          set -euo pipefail
          exec ${toolingPkgs.coreutils}/bin/timeout 60s ${inventoryTool} "$out" ${context}
        ''
      ) tooling;
      pnpmBinary = pkgs.fetchzip {
        url = "https://registry.npmjs.org/@pnpm/exe.linux-x64/-/exe.linux-x64-12.0.0.tgz";
        hash = "sha256-67iuIkleZ4f3ZcBsBPPyaYNvzvOcrUAED+UVDVcpXgw=";
      };
      pnpm = pkgs.stdenvNoCC.mkDerivation {
        pname = "pnpm";
        version = "12.0.0";
        dontUnpack = true;
        installPhase = ''
          set -euo pipefail
          exec ${tools.build} package-pnpm "$out" ${pnpmBinary} ${pkgs.coreutils}/bin/install ${pkgs.patchelf}/bin/patchelf ${pkgs.stdenv.cc.bintools.dynamicLinker} ${
            pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]
          }
        '';
        passthru.nodejs-slim = pkgs.nodejs_26;
      };
      pnpmDeps = pkgs.fetchPnpmDeps {
        pname = "phoenix-frontend";
        inherit pnpm;
        src = source inventory.dependencies;
        nativeBuildInputs = [ pkgs.nodejs_26 ];
        sourceRoot = "source/js";
        pnpmWorkspaces = [ "phoenix-ui..." ];
        fetcherVersion = 4;
        # Generated with: nix build ./phoenix#frontend (fetchPnpmDeps, fetcherVersion 4).
        hash = "sha256-NbIdFUxgE9joQxDQgiALyvxgLvJhuQo/skIWI7BakPo=";
      };
      frontend = pkgs.stdenvNoCC.mkDerivation {
        pname = "phoenix-frontend";
        version = "20.25.0";
        src = source (inventory.dependencies ++ inventory.sources);
        inherit pnpmDeps;
        pnpmRoot = "js";
        pnpmWorkspaces = [ "phoenix-ui..." ];
        nativeBuildInputs = [
          pkgs.nodejs_26
          pnpm
          pkgs.pnpmConfigHook
        ];
        PHOENIX_ENABLE_SOURCE_MAP = "True";
        pnpm_config_verify_deps_before_run = "false";
        pnpm_config_offline = "true";
        buildPhase = ''
          set -euo pipefail
          exec ${tools.build} build "$out" "$PWD" ${pnpm}/bin/pnpm
        '';
        dontInstall = true;
        dontFixup = true;
      };
      parity = pkgs.runCommand "phoenix-frontend-file-set" { } ''
        set -euo pipefail
        exec ${pkgs.coreutils}/bin/timeout 60s ${tools.check} "$out" ${frontend} ${./nix/frontend-static.txt}
      '';
      lintSource = source (
        pkgs.lib.concatMap (entry: entry.sources) (builtins.attrValues toolInputs) ++ [ "whine.yaml" ]
      );
      lint = toolingPkgs.runCommand "phoenix-frontend-tool-lint" { } ''
        set -euo pipefail
        exec ${checkRunner} "$out" ${lintSource} ${
          inputs.purescript-whine.packages.${system}.default
        }/bin/whine 'tools/**/*.purs'
      '';
    in
    {
      packages.${system}.frontend = frontend;
      checks.${system} = {
        frontend-file-set = parity;
        frontend-tool-inputs = pkgs.linkFarm "phoenix-frontend-tool-inputs" (
          pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) toolChecks
        );
        frontend-tool-lint = lint;
      };
      apps.${system}.frontend-inputs = {
        type = "app";
        program = toString tools.inputs;
      };
    };
}
