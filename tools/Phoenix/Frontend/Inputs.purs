module Phoenix.Frontend.Inputs (main) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Array as Data.Array
import Data.Foldable as Data.Foldable
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Data.String.Utils as Data.String.Utils
import Effect as Effect
import Effect.Exception as Effect.Exception
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Inventory as Platform.Node.Inventory

workspacePackages :: Array String
workspacePackages = [ "phoenix-client", "phoenix-config", "phoenix-evals", "phoenix-otel", "phoenix-testing" ]

refresh :: String -> String -> String -> Effect.Effect Unit
refresh output root git = do
  Node.Process.chdir root
  result <- Platform.Node.Inventory.graphImpl git [ "ls-files", "js", "schemas/openapi.json" ]
    { encoding: "utf8", timeout: 20000, maxBuffer: 33554432 }
  unless (Data.Nullable.toMaybe result.status == Data.Maybe.Just 0 && Data.Maybe.isNothing (Data.Nullable.toMaybe result.error))
    (Effect.Exception.throw "Cannot read tracked frontend input files")
  tracked <- Data.Maybe.maybe (Effect.Exception.throw "Git returned no inventory") pure (Data.Nullable.toMaybe result.stdout)
  let
    files = Data.Array.sort (Data.Array.filter (_ /= "") (Data.String.Utils.lines tracked))
    dependency file = Data.Array.elem file [ "js/package.json", "js/app/package.json", "js/.npmrc", "js/.pnpmfile.cjs", "js/pnpm-lock.yaml", "js/pnpm-workspace.yaml" ] || Data.Foldable.any (\package -> file == "js/packages/" <> package <> "/package.json") workspacePackages
    packageSource file package =
      let
        base = "js/packages/" <> package <> "/"
      in
        Data.String.Utils.startsWith (base <> "src/") file || Data.Array.elem file (map (base <> _) [ "tsconfig.json", "tsconfig.esm.json", "tsconfig.browser.json" ])
    appSource file = (Data.String.Utils.startsWith "js/app/src/" file && Data.Foldable.any (\extension -> Data.String.Utils.endsWith extension file) [ ".ts", ".tsx", ".css", ".grammar" ] && not (Data.String.Utils.startsWith "js/app/src/__mocks__/" file || Data.String.Utils.endsWith ".graphql.ts" file)) || Data.String.Utils.startsWith "js/app/static/" file || Data.Array.elem file [ "js/app/vite.config.mts", "js/app/relay.config.js", "js/app/schema.graphql", "js/tsconfig.base.json", "js/tsconfig.base.esm.json", "schemas/openapi.json" ]
    dependencies = Data.Array.filter dependency files
    sources = Data.Array.filter (\file -> not (dependency file) && (appSource file || Data.Foldable.any (packageSource file) workspacePackages)) files
  Platform.Node.Build.writeImpl output ("{\n  \"dependencies\": [\n" <> render dependencies <> "\n  ],\n  \"sources\": [\n" <> render sources <> "\n  ]\n}\n")
  where
  render = Data.String.joinWith ",\n" <<< map (\file -> "    " <> Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson file))

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  case arguments of
    [ output, root, git ] -> refresh output root git
    _ -> Effect.Exception.throw "Expected inventory output, repository root, and Git executable"
