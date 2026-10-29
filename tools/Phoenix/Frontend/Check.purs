module Phoenix.Frontend.Check (main) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Array as Data.Array
import Data.String as Data.String
import Data.Traversable as Data.Traversable
import Effect as Effect
import Effect.Exception as Effect.Exception
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build

staticFiles :: String -> String -> Effect.Effect (Array String)
staticFiles root relative = do
  entries <- Platform.Node.Build.entriesImpl (root <> "/" <> relative)
  groups <- Data.Traversable.traverse
    ( \entry -> do
        let
          path = if relative == "" then entry else relative <> "/" <> entry
        directory <- Platform.Node.Build.directoryImpl (root <> "/" <> path)
        if directory then staticFiles root path else pure [ path ]
    )
    entries
  pure (Data.Array.sort (Data.Array.concat groups))

fileDiff :: Array String -> Array String -> Array String
fileDiff expected actual =
  map ("- " <> _) (Data.Array.difference expected actual)
    <> map ("+ " <> _) (Data.Array.difference actual expected)

check :: String -> String -> String -> Effect.Effect Unit
check output frontend reference = do
  started <- Node.Process.uptime
  expected <- Data.Array.sort <<< Data.Array.filter (_ /= "") <<< Data.String.split (Data.String.Pattern "\n") <$> Platform.Node.Build.readImpl reference
  unless (Data.Array.length expected == 37 && Data.Array.length (Data.Array.nub expected) == 37 && Data.Array.elem ".vite/manifest.json" expected)
    (Effect.Exception.throw "Frontend reference must contain 37 unique paths including .vite/manifest.json")
  actual <- staticFiles frontend ""
  let
    diff = fileDiff expected actual
    render = Data.String.joinWith "\n"
    missingControl = not (Data.Array.null (fileDiff expected (Data.Array.filter (_ /= ".vite/manifest.json") actual)))
    addedControl = not (Data.Array.null (fileDiff expected (actual <> [ ".unexpected-file" ])))
  Platform.Node.Build.mkdirImpl output
  Platform.Node.Build.writeImpl (output <> "/expected.txt") (render expected <> "\n")
  Platform.Node.Build.writeImpl (output <> "/actual.txt") (render actual <> "\n")
  Platform.Node.Build.writeImpl (output <> "/diff.txt") (if Data.Array.null diff then "" else render diff <> "\n")
  unless (Data.Array.null diff) (Effect.Exception.throw ("Frontend file-set mismatch:\n" <> render diff))
  unless (missingControl && addedControl) (Effect.Exception.throw "Frontend file-set rejection controls failed")
  finished <- Node.Process.uptime
  unless (finished - started < 60.0) (Effect.Exception.throw "Frontend file-set check exceeded 60 seconds")
  Platform.Node.Build.writeImpl (output <> "/receipt.json")
    (Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson { frontend, reference, entries: Data.Array.length actual, emptyDiff: true, missingHiddenFileRejected: missingControl, addedFileRejected: addedControl, elapsedSeconds: finished - started, node: Node.Process.version }) <> "\n")

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  case arguments of
    [ output, frontend, reference ] -> check output frontend reference
    _ -> Effect.Exception.throw "Expected check output, frontend output, and reference file set"
