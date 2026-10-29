module Phoenix.Python.Inputs (main) where

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

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  case arguments of
    [ root, git, reference ] -> do
      result <- Platform.Node.Inventory.graphImpl git [ "-C", root, "ls-files", "src/phoenix", "pyproject.toml", "README.md", "LICENSE", "IP_NOTICE" ]
        { encoding: "utf8", timeout: 20000, maxBuffer: 33554432 }
      unless (Data.Nullable.toMaybe result.status == Data.Maybe.Just 0 && Data.Maybe.isNothing (Data.Nullable.toMaybe result.error))
        (Effect.Exception.throw "Cannot read tracked Python source files")
      tracked <- Data.Maybe.maybe (Effect.Exception.throw "Git returned no Python inventory") pure (Data.Nullable.toMaybe result.stdout)
      let
        excluded file = Data.Foldable.any (\prefix -> Data.String.Utils.startsWith ("src/phoenix/" <> prefix <> "/") file) [ "client", "evals", "otel", "server/static" ] || Data.Array.elem file [ "src/phoenix/db/README.md", "src/phoenix/trace/dsl/README.md", "src/phoenix/server/api/README.md" ]
        files = Data.Array.sort (Data.Array.filter (\file -> file /= "" && not (excluded file)) (Data.String.Utils.lines tracked))
      Platform.Node.Build.writeImpl (root <> "/nix/python-source-inputs.json") ("[\n" <> Data.String.joinWith ",\n" (map (\file -> "  " <> Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson file)) files) <> "\n]\n")
      Platform.Node.Build.copyImpl reference (root <> "/nix/python-distributions.txt")
    _ ->
      Effect.Exception.throw "Expected repository root, Git executable, and distribution reference"
