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
      packageToolInputs = builtins.fromJSON (builtins.readFile ./nix/package-tool-inputs.json);
      smokeInputs = builtins.fromJSON (builtins.readFile ./nix/package-smoke-inputs.json);
      allToolInputs = toolInputs // pythonToolInputs // packageToolInputs;
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
      frontendGraphModules = pkgs.linkFarm "phoenix-frontend-graph-node-modules" [
        {
          name = "typescript";
          path = pkgs.fetchzip {
            url = "https://registry.npmjs.org/typescript/-/typescript-6.0.3.tgz";
            hash = "sha256-3+cPVJRyySKkVrRsOld6ShMzHwOP7UFFy0mrq3ZoBKA=";
          };
        }
      ];
      tooling = builtins.mapAttrs (
        _: entry:
        purs.purs {
          srcs = [
            "${source entry.sources}/tools"
          ]
          ++ map (directory: "${platformSource entry.platform}/${directory}") (
            entry.platformDirectories or (pkgs.lib.optional (entry.platform != [ ]) "tools")
          );
          dependencies = entry.dependencies;
          nodejs = if entry.module == "Phoenix.Frontend.Inputs" then pkgs.nodejs_26 else toolingPkgs.nodejs;
          foreign = pkgs.lib.optionalAttrs (entry.module == "Phoenix.Frontend.Inputs") {
            "Platform.Node.Frontend".node_modules = frontendGraphModules;
          };
        }
      ) allToolInputs;
      tools = builtins.mapAttrs (
        name: project:
        project.script {
          module = allToolInputs.${name}.module;
        }
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
              ]
              ++ pkgs.lib.optional (entry.platform != [ ]) {
                root = platformSource entry.platform;
                files = entry.platform;
              };
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
        src = pnpmBinary;
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];
        dontBuild = true;
        dontStrip = true;
        installPhase = ''
          ${pkgs.coreutils}/bin/install -Dm755 pnpm "$out/bin/pnpm"
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
      frontendDiscoveryCandidates = fs.toSource {
        root = ./.;
        fileset = fs.unions [
          (fs.fromSource (
            pkgs.lib.cleanSourceWith {
              src = ./js;
              filter =
                path: type:
                let
                  relative = pkgs.lib.removePrefix (toString ./js + "/") path;
                  segments = pkgs.lib.splitString "/" relative;
                  name = builtins.baseNameOf path;
                  publicAsset = pkgs.lib.hasPrefix "app/static/" relative;
                in
                publicAsset
                || (
                  !builtins.any (
                    segment:
                    builtins.elem segment [
                      "node_modules"
                      "__tests__"
                      "__mocks__"
                      "tests"
                      "test"
                      "fixtures"
                      "__fixtures__"
                      ".agents"
                    ]
                  ) segments
                  && !pkgs.lib.hasPrefix "examples/" relative
                  && !pkgs.lib.hasPrefix "benchmarks/" relative
                  && (
                    type == "directory"
                    || (
                      !(pkgs.lib.hasSuffix ".md" name)
                      && !(pkgs.lib.hasSuffix ".tsbuildinfo" name)
                      && builtins.match ".*\\.(test|spec|stories)\\..*" name == null
                    )
                  )
                );
            }
          ))
          (fs.fileFilter (file: file.name == "package.json") ./js)
          ./schemas/openapi.json
        ];
      };
      frontendProductInputs =
        mode:
        pkgs.stdenvNoCC.mkDerivation {
          name = "phoenix-frontend-product-inputs-${mode}";
          src = frontendDiscoveryCandidates;
          inherit pnpmDeps;
          pnpmRoot = "js";
          pnpmWorkspaces = [ "phoenix-ui..." ];
          nativeBuildInputs = [
            pkgs.nodejs_26
            pnpm
            pkgs.pnpmConfigHook
            pkgs.findutils
          ];
          PHOENIX_ENABLE_SOURCE_MAP = "True";
          pnpm_config_verify_deps_before_run = "false";
          pnpm_config_offline = "true";
          buildPhase = ''
            set -euo pipefail
            exec ${pkgs.coreutils}/bin/timeout 60s ${tools.inputs} ${mode} "$out" "$PWD" ${pnpm}/bin/pnpm ${./nix/frontend-assets.json} ${
              if mode == "check" then "${./nix/frontend-inputs.json}" else "-"
            }
          '';
          dontInstall = true;
          dontFixup = true;
        };
      frontendInputDiscovery = frontendProductInputs "generate";
      python = pkgs.python313;
      pythonSourceInputs = builtins.fromJSON (builtins.readFile ./nix/python-source-inputs.json);
      pythonProject = builtins.fromTOML (builtins.readFile ./pyproject.toml);
      pythonBuildConfig = pkgs.writeText "phoenix-python-build-config.json" (
        builtins.toJSON {
          inherit (pythonProject.tool.hatch.build.targets.wheel) packages artifacts;
          excluded = pythonProject.tool.hatch.build.targets.wheel.exclude;
          backend = pythonProject.build-system.build-backend;
          onlyPackages = pythonProject.tool.hatch.build.only-packages;
          version = pythonProject.tool.hatch.version.path;
          readme = pythonProject.project.readme;
          licenses = pythonProject.project.license-files.paths;
          entries = builtins.attrValues pythonProject.project.scripts;
          wheelKeys = builtins.attrNames pythonProject.tool.hatch.build.targets.wheel;
          buildKeys = builtins.attrNames pythonProject.tool.hatch.build;
        }
      );
      pythonDiscoveryCandidates = fs.toSource {
        root = ./.;
        fileset = fs.unions [
          (fs.unions (
            map (path: ./. + "/${path}") (
              [
                "pyproject.toml"
                pythonProject.project.readme
              ]
              ++ pythonProject.project.license-files.paths
            )
          ))
          (fs.fromSource (
            pkgs.lib.cleanSourceWith {
              src = ./src/phoenix;
              filter =
                path: _:
                let
                  relative = pkgs.lib.removePrefix (toString ./src/phoenix + "/") path;
                in
                !builtins.any (prefix: relative == prefix || pkgs.lib.hasPrefix (prefix + "/") relative) [
                  "client"
                  "evals"
                  "otel"
                  "server/static"
                ];
            }
          ))
        ];
      };
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
      deno = pkgs.stdenvNoCC.mkDerivation {
        pname = "phoenix-deno";
        version = "2.1.4";
        src = pkgs.fetchurl {
          url = "https://github.com/denoland/deno/releases/download/v2.1.4/deno-x86_64-unknown-linux-gnu.zip";
          hash = "sha256-VKgZOczLKvEUxNCmilVM9KBLHwhyjnD2Y/g3gd4Z14U=";
        };
        sourceRoot = ".";
        nativeBuildInputs = [
          pkgs.unzip
          pkgs.autoPatchelfHook
        ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];
        dontBuild = true;
        dontStrip = true;
        installPhase = ''
          ${pkgs.coreutils}/bin/install -Dm755 deno "$out/bin/deno"
        '';
      };
      wasmBinary = pkgs.fetchurl {
        url = "https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python%2F3.12.0%2B20231211-040d5a6/python-3.12.0.wasm";
        hash = "sha256-5dxaOYsHtU6o/bUDv2j7WD1TPxDsP5MJY+ArlQX3p2M=";
      };
      evaluatorRuntimes = pkgs.linkFarm "phoenix-evaluator-runtimes" [
        {
          name = "bin/deno";
          path = "${deno}/bin/deno";
        }
        {
          name = "bin/monty";
          path = "${environment}/bin/monty";
        }
        {
          name = "share/phoenix/python-3.12.0.wasm";
          path = wasmBinary;
        }
      ];
      phoenix =
        pkgs.runCommand "phoenix-20.25.0-native"
          {
            nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
            passthru.pythonEnvironment = environment;
            meta.mainProgram = "phoenix";
          }
          ''
            makeWrapper ${environment}/bin/python "$out/bin/phoenix" \
              --add-flags "-m phoenix.server.main serve" \
              --prefix PATH : ${evaluatorRuntimes}/bin \
              --set PHOENIX_WASM_BINARY_PATH ${wasmBinary}
          '';
      smokeDependencies = toolingPkgs.importNpmLock.buildNodeModules {
        npmRoot = source smokeInputs.dependencies + "/nix/package-smoke";
        nodejs = toolingPkgs.nodejs;
      };
      smokePolicy =
        (builtins.fromJSON (builtins.readFile (inputs.platform + "/nix/test-policy.json")))
        // {
          cleanupReserveMilliseconds = 4000;
        };
      smokeSupport = pkgs.linkFarm "phoenix-package-smoke-support" [
        {
          name = "cucumber.json";
          path = pkgs.writeText "phoenix-package-cucumber.json" "{}";
        }
        {
          name = "steps.mjs";
          path = pkgs.writeText "phoenix-package-steps.mjs" (
            builtins.replaceStrings
              [ "@steps@" "@deadline@" "@cucumber@" ]
              [
                "${tooling.package-smoke-steps.output { }}/Phoenix.Package.Smoke/index.js"
                (toString smokePolicy.singleMilliseconds)
                "${smokeDependencies}/node_modules/@cucumber/cucumber/lib/wrapper.mjs"
              ]
              (builtins.readFile (source smokeInputs.registration + "/features/native-package.mjs"))
          );
        }
      ];
      smokeContext = pkgs.writeText "phoenix-package-smoke.json" (
        builtins.toJSON {
          package = phoenix;
          curl = "${pkgs.curl}/bin/curl";
          node = "${toolingPkgs.nodejs}/bin/node";
          cucumber = "${smokeDependencies}/node_modules/@cucumber/cucumber/bin/cucumber.js";
          support = smokeSupport;
          feature = "${source smokeInputs.feature}/features/native-package.feature";
          processTable = "${toolingPkgs.procps}/bin/ps";
          timeout = "${pkgs.coreutils}/bin/timeout";
          policy = smokePolicy;
        }
      );
      packageSmoke =
        (pkgs.runCommand "phoenix-package-health" { } ''
          set -euo pipefail
          exec ${checkRunner} "$out/runner" "$PWD" ${tools.package-smoke-runner} "$out" ${smokeContext}
        '').overrideAttrs
          {
            passthru = {
              context = smokeContext;
              runner = tools.package-smoke-runner;
              steps = tooling.package-smoke-steps.output { };
            };
          };
      pythonProductInputs =
        mode:
        pkgs.stdenvNoCC.mkDerivation {
          name = "phoenix-python-product-inputs-${mode}";
          src = pythonDiscoveryCandidates;
          buildPhase = ''
            set -euo pipefail
            exec ${pkgs.coreutils}/bin/timeout 60s ${tools.python-inputs} ${mode} "$out" "$PWD" ${pythonBuildConfig} ${
              if mode == "check" then "${./nix/python-source-inputs.json}" else "-"
            } ${if mode == "check" then "${environment}/${python.sitePackages}" else "-"} ${python}/bin/python
          '';
          dontInstall = true;
          dontFixup = true;
        };
      pythonInputDiscovery = pythonProductInputs "generate";
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
      packageLintSource = source (
        pkgs.lib.concatMap (entry: entry.sources) (builtins.attrValues packageToolInputs)
        ++ [ "whine.yaml" ]
      );
      packageLint = toolingPkgs.runCommand "phoenix-package-tool-lint" { } ''
        set -euo pipefail
        exec ${checkRunner} "$out" ${packageLintSource} ${
          inputs.purescript-whine.packages.${system}.default
        }/bin/whine 'tools/**/*.purs'
      '';
    in
    {
      packages.${system} = {
        inherit frontend;
        frontend-inputs-discovery = frontendInputDiscovery;
        python-inputs-discovery = pythonInputDiscovery;
        python-source = pythonSet.arize-phoenix;
        evaluator-runtimes = evaluatorRuntimes;
        evaluator-deno = deno;
        inherit phoenix;
        default = phoenix;
      };
      checks.${system} = {
        package-smoke = packageSmoke;
        package-tool-lint = packageLint;
        package-tool-inputs =
          (pkgs.linkFarm "phoenix-package-tool-inputs" (
            pkgs.lib.mapAttrsToList (name: _: {
              inherit name;
              path = toolChecks.${name};
            }) packageToolInputs
          )).overrideAttrs
            {
              passthru.entries = pkgs.lib.genAttrs (builtins.attrNames packageToolInputs) (
                name: toolChecks.${name}
              );
            };
        frontend-product-inputs = frontendProductInputs "check";
        frontend-tool-inputs = pkgs.linkFarm "phoenix-frontend-tool-inputs" (
          pkgs.lib.mapAttrsToList (name: _: {
            inherit name;
            path = toolChecks.${name};
          }) toolInputs
        );
        frontend-tool-lint = lint;
        python-product-inputs = pythonProductInputs "check";
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
          program = toString (
            pkgs.writeShellScript "phoenix-frontend-inputs" ''
              set -euo pipefail
              exec ${tools.inputs} export ${frontendInputDiscovery}/inventory.json "$@"
            ''
          );
        };
        python-inputs = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "phoenix-python-inputs" ''
              set -euo pipefail
              exec ${tools.python-inputs} export ${pythonInputDiscovery}/inventory.json "$@"
            ''
          );
        };
      };
    };
}
