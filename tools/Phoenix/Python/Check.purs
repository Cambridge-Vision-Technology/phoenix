module Phoenix.Python.Check (main) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Argonaut.Parser as Data.Argonaut.Parser
import Data.Array as Data.Array
import Data.Bifunctor as Data.Bifunctor
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Data.Traversable as Data.Traversable
import Effect as Effect
import Effect.Exception as Effect.Exception
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Inventory as Platform.Node.Inventory

run :: String -> String -> Array String -> Effect.Effect String
run output python arguments = do
  result <- Platform.Node.Inventory.graphImpl python arguments { encoding: "utf8", timeout: 55000, maxBuffer: 33554432 }
  let
    stdout = Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe result.stdout)
    stderr = Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe result.stderr)
  Platform.Node.Build.writeImpl (output <> "/stdout.txt") stdout
  Platform.Node.Build.writeImpl (output <> "/stderr.txt") stderr
  unless (Data.Nullable.toMaybe result.status == Data.Maybe.Just 0 && Data.Maybe.isNothing (Data.Nullable.toMaybe result.error))
    (Effect.Exception.throw ("Python check failed: " <> stderr))
  pure stdout

normaliseName :: String -> String
normaliseName = Data.String.replaceAll (Data.String.Pattern ".") (Data.String.Replacement "_") <<< Data.String.replaceAll (Data.String.Pattern "-") (Data.String.Replacement "_") <<< Data.String.toLower

parity :: String -> String -> String -> String -> String -> Effect.Effect Unit
parity output python pip site reference = do
  referenceText <- Platform.Node.Build.readImpl reference
  expected <- Data.Array.sort <$> Data.Traversable.traverse
    ( \entry -> case Data.String.split (Data.String.Pattern "-") entry of
        [ name, version ] -> pure (normaliseName name <> "-" <> version)
        _ -> Effect.Exception.throw ("Invalid distribution reference entry: " <> entry)
    )
    (Data.Array.filter (_ /= "") (Data.String.split (Data.String.Pattern "\n") referenceText))
  unless (Data.Array.length expected == 215 && Data.Array.length (Data.Array.nub expected) == 215)
    (Effect.Exception.throw "Distribution reference must contain exactly 215 unique entries")
  text <- run output python [ pip, "--isolated", "--disable-pip-version-check", "list", "--path", site, "--format=json" ]
  rows <- case Data.Argonaut.Parser.jsonParser text >>= Data.Bifunctor.lmap show <<< Data.Argonaut.Decode.decodeJson of
    Data.Either.Left error -> Effect.Exception.throw ("Invalid pip distribution inventory: " <> error)
    Data.Either.Right (values :: Array { name :: String, version :: String }) -> pure values
  let
    actual = Data.Array.sort (map (\row -> normaliseName row.name <> "-" <> row.version) rows)
    diff = map ("- " <> _) (Data.Array.difference expected actual) <> map ("+ " <> _) (Data.Array.difference actual expected)
    render = Data.String.joinWith "\n"
    missingRejected = expected /= Data.Array.drop 1 actual
    addedRejected = expected /= Data.Array.sort (actual <> [ "unexpected_distribution-0" ])
    versionRejected = expected /= Data.Array.sort (Data.Array.drop 1 actual <> [ "aioboto3-0" ])
  Platform.Node.Build.writeImpl (output <> "/expected.txt") (render expected <> "\n")
  Platform.Node.Build.writeImpl (output <> "/reference.txt") referenceText
  Platform.Node.Build.writeImpl (output <> "/actual.txt") (render actual <> "\n")
  Platform.Node.Build.writeImpl (output <> "/diff.txt") (if Data.Array.null diff then "" else render diff <> "\n")
  unless (Data.Array.null diff && Data.Array.length actual == 215 && Data.Array.length (Data.Array.nub actual) == 215)
    (Effect.Exception.throw ("Distribution mismatch:\n" <> render diff))
  unless (missingRejected && addedRejected && versionRejected) (Effect.Exception.throw "Distribution rejection controls failed")
  Platform.Node.Build.writeImpl (output <> "/parity.json")
    (Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson { entries: Data.Array.length actual, emptyDiff: true, missingRejected, addedRejected, versionRejected, metadataBackend: "pip importlib.metadata", reference }) <> "\n")

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  started <- Node.Process.uptime
  case arguments of
    [ "import", output, environment ] -> do
      Platform.Node.Build.mkdirImpl output
      home <- Node.Process.cwd
      Node.Process.setEnv "HOME" home
      void (run output (environment <> "/bin/python") [ "-c", "import phoenix.server.main" ])
      receipt output environment started "import phoenix.server.main"
    [ "parity", output, environment, pip, site, reference ] -> do
      Platform.Node.Build.mkdirImpl output
      parity output (environment <> "/bin/python") pip site reference
      receipt output environment started "distribution parity"
    _ ->
      Effect.Exception.throw "Expected import or parity with output and environment inputs"
  where
  receipt output environment started operation = do
    finished <- Node.Process.uptime
    unless (finished - started < 60.0) (Effect.Exception.throw "Python check exceeded 60 seconds")
    Platform.Node.Build.writeImpl (output <> "/receipt.json")
      (Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson { environment, operation, exitCode: 0, elapsedSeconds: finished - started, node: Node.Process.version }) <> "\n")
