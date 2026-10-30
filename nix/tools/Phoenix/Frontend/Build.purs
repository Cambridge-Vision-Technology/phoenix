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
    [ "build", output, root, pnpm ] -> do
      Platform.Node.Build.executeImpl pnpm [ "--filter", "phoenix-ui...", "run", "build" ] (root <> "/js")
      Platform.Node.Build.copyImpl (root <> "/src/phoenix/server/static") output
    _ ->
      Effect.Exception.throw "Expected build with output, source root and pnpm"
