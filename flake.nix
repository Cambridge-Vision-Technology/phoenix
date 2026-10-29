{
  description = "Native Phoenix packaging";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/31ecbaca1bdefa45dffc409f0250bd8039ea0010";
    tooling-nixpkgs.url = "github:NixOS/nixpkgs/3497aa5c9457a9d88d71fa93a4a8368816fbeeba";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix/2c8df1383b32e5443c921f61224b198a2282a657";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix/1610e554e579c3d47b47c8a32d47042116d0e153";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs/042904167604c681a090c07eb6967b4dd4dae88c";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
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
      pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate = package: inputs.nixpkgs.lib.getName package == "arize-phoenix";
      };
      toolingPkgs = import inputs.tooling-nixpkgs { inherit system; };
      fs = pkgs.lib.fileset;
      inventory = builtins.fromJSON (builtins.readFile ./nix/frontend-inputs.json);
      toolInputs = builtins.fromJSON (builtins.readFile ./nix/frontend-tool-inputs.json);
      pythonToolInputs = builtins.fromJSON (builtins.readFile ./nix/python-tool-inputs.json);
      allToolInputs = toolInputs // pythonToolInputs;
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
      ) allToolInputs;
      tools = builtins.mapAttrs (
        name: project: project.script { module = allToolInputs.${name}.module; }
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
          entry = allToolInputs.${name};
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
      python = pkgs.python313;
      pythonSourceInputs = builtins.fromJSON (builtins.readFile ./nix/python-source-inputs.json);
      pythonRegistry = builtins.fromJSON (builtins.readFile ./nix/python-registry.json);
      pythonWorkspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
      pythonLock = builtins.fromTOML (builtins.readFile ./uv.lock);
      pythonOverlay = pythonWorkspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
        dependencies.arize-phoenix = [
          "container"
          "pg"
        ];
      };
      pythonOverrides =
        final: prev:
        (builtins.mapAttrs (
          name: wheel:
          final.callPackage (inputs.uv2nix.lib.build.remote
            {
              config = pythonWorkspace.config;
              workspaceRoot = ./.;
              defaultSourcePreference = "wheel";
            }
            (
              inputs.uv2nix.lib.lock1.parsePackage { } (
                (builtins.head (builtins.filter (package: package.name == name) pythonLock.package))
                // {
                  source.registry = "https://pypi.org/simple";
                  wheels = [ wheel ];
                }
              )
            )
          ) { }
        ) pythonRegistry)
        // {
          wasmtime = prev.wasmtime.overrideAttrs (old: {
            src = pkgs.fetchurl (
              builtins.removeAttrs
                (builtins.head (
                  builtins.filter (wheel: pkgs.lib.hasSuffix "-manylinux1_x86_64.whl" wheel.url)
                    (builtins.head (builtins.filter (package: package.name == "wasmtime") pythonLock.package)).wheels
                ))
                [
                  "size"
                  "upload-time"
                ]
            );
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.stdenv.cc.cc.lib ];
          });
          arize-phoenix = prev.arize-phoenix.overrideAttrs {
            version = "20.25.0";
            src = pkgs.symlinkJoin {
              name = "phoenix-python-source";
              paths = [
                (source pythonSourceInputs)
                (pkgs.linkFarm "phoenix-python-static" [
                  {
                    name = "src/phoenix/server/static";
                    path = frontend;
                  }
                ])
              ];
            };
          };
        };
      pythonSet =
        (pkgs.callPackage inputs.pyproject-nix.build.packages { inherit python; }).overrideScope
          (
            pkgs.lib.composeManyExtensions [
              inputs.pyproject-build-systems.overlays.default
              pythonOverlay
              pythonOverrides
            ]
          );
      environment = pythonSet.mkVirtualEnv "phoenix-20.25.0" {
        arize-phoenix = [
          "container"
          "pg"
        ];
      };
      pythonImport = pkgs.runCommand "phoenix-python-import" { } ''
        set -euo pipefail
        exec ${pkgs.coreutils}/bin/timeout 60s ${tools.python-check} import "$out" ${environment}
      '';
      pythonParity = pkgs.runCommand "phoenix-python-distributions" { } ''
        set -euo pipefail
        exec ${pkgs.coreutils}/bin/timeout 60s ${tools.python-check} parity "$out" ${environment} ${python.pkgs.pip}/${python.sitePackages}/pip ${environment}/${python.sitePackages} ${./nix/python-distributions.txt}
      '';
      pythonStatic = pkgs.runCommand "phoenix-python-static-file-set" { } ''
        set -euo pipefail
        exec ${pkgs.coreutils}/bin/timeout 60s ${tools.check} "$out" ${environment}/${python.sitePackages}/phoenix/server/static ${./nix/frontend-static.txt}
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
      pythonLintSource = source (
        pkgs.lib.concatMap (entry: entry.sources) (builtins.attrValues pythonToolInputs) ++ [ "whine.yaml" ]
      );
      pythonLint = toolingPkgs.runCommand "phoenix-python-tool-lint" { } ''
        set -euo pipefail
        exec ${checkRunner} "$out" ${pythonLintSource} ${
          inputs.purescript-whine.packages.${system}.default
        }/bin/whine 'tools/**/*.purs'
      '';
    in
    {
      packages.${system} = {
        inherit frontend;
        default = environment;
      };
      checks.${system} = {
        frontend-file-set = parity;
        frontend-tool-inputs = pkgs.linkFarm "phoenix-frontend-tool-inputs" (
          pkgs.lib.mapAttrsToList (name: _: {
            inherit name;
            path = toolChecks.${name};
          }) toolInputs
        );
        frontend-tool-lint = lint;
        python-import = pythonImport;
        python-distributions = pythonParity;
        python-static-file-set = pythonStatic;
        python-tool-lint = pythonLint;
        python-tool-inputs = pkgs.linkFarm "phoenix-python-tool-inputs" (
          pkgs.lib.mapAttrsToList (name: _: {
            inherit name;
            path = toolChecks.${name};
          }) pythonToolInputs
        );
      };
      apps.${system} = {
        frontend-inputs = {
          type = "app";
          program = toString tools.inputs;
        };
        python-inputs = {
          type = "app";
          program = toString tools.python-inputs;
        };
      };
    };
}
