module Phoenix.Python.Check (main) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Argonaut.Parser as Data.Argonaut.Parser
import Data.Array as Data.Array
import Data.Bifunctor as Data.Bifunctor
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
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

distributionDecision :: Array String -> Int -> Array String -> { accepted :: Boolean, diff :: Array String, entries :: Int, uniqueEntries :: Int, metadataEntries :: Int }
distributionDecision expected metadataEntries actual =
  let
    diff = map ("- " <> _) (Data.Array.difference expected actual) <> map ("+ " <> _) (Data.Array.difference actual expected)
    entries = Data.Array.length actual
    uniqueEntries = Data.Array.length (Data.Array.nub actual)
    accepted = Data.Array.null diff && entries == 215 && uniqueEntries == 215 && metadataEntries == 215
  in
    { accepted, diff, entries, uniqueEntries, metadataEntries }

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
  siteEntries <- Platform.Node.Build.entriesImpl site
  let
    metadataEntries = Data.Array.filter (\entry -> Data.Maybe.isJust (Data.String.stripSuffix (Data.String.Pattern ".dist-info") entry) || Data.Maybe.isJust (Data.String.stripSuffix (Data.String.Pattern ".egg-info") entry)) siteEntries
  text <- run output python [ pip, "--isolated", "--disable-pip-version-check", "list", "--path", site, "--format=json" ]
  rows <- case Data.Argonaut.Parser.jsonParser text >>= Data.Bifunctor.lmap show <<< Data.Argonaut.Decode.decodeJson of
    Data.Either.Left error -> Effect.Exception.throw ("Invalid pip distribution inventory: " <> error)
    Data.Either.Right (values :: Array { name :: String, version :: String }) -> pure values
  let
    actual = Data.Array.sort (map (\row -> normaliseName row.name <> "-" <> row.version) rows)
    positive = distributionDecision expected (Data.Array.length metadataEntries) actual
    diff = positive.diff
    render = Data.String.joinWith "\n"
  Platform.Node.Build.writeImpl (output <> "/expected.txt") (render expected <> "\n")
  Platform.Node.Build.writeImpl (output <> "/reference.txt") referenceText
  Platform.Node.Build.writeImpl (output <> "/actual.txt") (render actual <> "\n")
  Platform.Node.Build.writeImpl (output <> "/diff.txt") (if Data.Array.null diff then "" else render diff <> "\n")
  unless positive.accepted (Effect.Exception.throw ("Distribution mismatch:\n" <> show positive))
  first <- Data.Maybe.maybe (Effect.Exception.throw "Distribution controls require an existing entry") pure (Data.Array.head rows)
  let
    firstName = normaliseName first.name
    original = firstName <> "-" <> first.version
    changed = firstName <> "-" <> first.version <> ".control"
    mutatedVersion = map (\entry -> if entry == original then changed else entry) actual
    controls =
      [ { label: "missing", result: distributionDecision expected 214 (Data.Array.filter (_ /= original) actual) }
      , { label: "added", result: distributionDecision expected 216 (actual <> [ "unexpected_distribution-0" ]) }
      , { label: "same-name-wrong-version", result: distributionDecision expected 215 mutatedVersion }
      , { label: "duplicate", result: distributionDecision expected 215 (Data.Array.drop 1 actual <> [ Data.Maybe.fromMaybe original (Data.Array.last actual) ]) }
      , { label: "hidden-metadata", result: distributionDecision expected 216 actual }
      ]
  Data.Foldable.traverse_ (\control -> unless (not control.result.accepted) (Effect.Exception.throw ("Distribution control was accepted: " <> control.label))) controls
  Platform.Node.Build.writeImpl (output <> "/controls.json")
    (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson { original, changed, controls }) <> "\n")
  Platform.Node.Build.writeImpl (output <> "/parity.json")
    (Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson { decision: positive, controlsRejected: Data.Foldable.all (not <<< _.result.accepted) controls, metadataBackend: "pip importlib.metadata", reference }) <> "\n")

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
