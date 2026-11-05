module Phoenix.Frontend.Build (main) where

import Prelude

import Data.Array as Data.Array
import Effect as Effect
import Effect.Exception as Effect.Exception
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  case arguments of
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
