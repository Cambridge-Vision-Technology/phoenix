module Phoenix.Frontend.Build (main) where

import Prelude

import Data.Array as Data.Array
import Data.Foldable as Data.Foldable
import Effect as Effect
import Effect.Exception as Effect.Exception
import Node.Process as Node.Process
import Node.FS.Sync as Node.FS.Sync
import Node.FS.Perms as Node.FS.Perms
import Platform.Node.Build as Platform.Node.Build

copyRelay :: String -> String -> String -> Boolean -> Effect.Effect Unit
copyRelay input output relative generated = do
  let
    target = output <> "/" <> relative
    permissions directory = Node.FS.Perms.mkPerms (Node.FS.Perms.mkPerm true true directory) (Node.FS.Perms.mkPerm true false directory) (Node.FS.Perms.mkPerm true false directory)
  when generated do
    Platform.Node.Build.mkdirImpl target
    Node.FS.Sync.chmod target (permissions true)
  entries <- Platform.Node.Build.entriesImpl (input <> "/" <> relative)
  Data.Foldable.for_ entries \entry -> do
    let path = relative <> "/" <> entry
    directory <- Platform.Node.Build.directoryImpl (input <> "/" <> path)
    if directory then copyRelay input output path (generated || entry == "__generated__")
    else when generated do
      exists <- Platform.Node.Build.existsImpl (output <> "/" <> path)
      when exists (Node.FS.Sync.chmod (output <> "/" <> path) (permissions false))
      text <- Platform.Node.Build.readImpl (input <> "/" <> path)
      Platform.Node.Build.writeImpl (output <> "/" <> path) text

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  case arguments of
    [ "relay", output, root, pnpm ] -> do
      Platform.Node.Build.executeImpl pnpm [ "--filter", "phoenix-ui", "run", "build:relay" ] (root <> "/js")
      copyRelay root output "js/app/src" false
    [ "export-relay", input, output ] ->
      copyRelay input output "js/app/src" false
    [ "export-generated", input, output ] -> do
      text <- Platform.Node.Build.readImpl input
      Platform.Node.Build.writeImpl output text
    [ "check-generated", expected, actual ] -> do
      wanted <- Platform.Node.Build.readImpl expected
      observed <- Platform.Node.Build.readImpl actual
      unless (wanted == observed) (Effect.Exception.throw "Generated Legend presentation is stale; regenerate it from its PureScript source")
    [ "build", output, root, pnpm ] -> do
      Platform.Node.Build.executeImpl pnpm [ "--filter", "phoenix-ui...", "run", "build" ] (root <> "/js")
      Platform.Node.Build.copyImpl (root <> "/src/phoenix/server/static") output
    [ "typecheck", output, root, pnpm ] -> do
      Platform.Node.Build.executeImpl pnpm [ "--filter", "phoenix-ui^...", "run", "build" ] (root <> "/js")
      Platform.Node.Build.executeImpl pnpm [ "--filter", "phoenix-ui", "run", "build:relay" ] (root <> "/js")
      Platform.Node.Build.executeImpl pnpm [ "--filter", "phoenix-ui", "run", "typecheck" ] (root <> "/js")
      Platform.Node.Build.writeImpl output "Phoenix product TypeScript check passed\n"
    _ ->
      Effect.Exception.throw "Expected build with output, source root and pnpm"
