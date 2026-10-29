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
    [ "package-pnpm", output, binary, install, patchelf, interpreter, libraries ] -> do
      Platform.Node.Build.executeImpl install [ "-Dm755", binary <> "/pnpm", output <> "/bin/pnpm" ] "/tmp"
      Platform.Node.Build.executeImpl patchelf [ "--set-interpreter", interpreter, "--set-rpath", libraries, output <> "/bin/pnpm" ] output
    [ "build", output, root, pnpm ] -> do
      Platform.Node.Build.executeImpl pnpm [ "--filter", "phoenix-ui...", "run", "build" ] (root <> "/js")
      Platform.Node.Build.copyImpl (root <> "/src/phoenix/server/static") output
    _ ->
      Effect.Exception.throw "Expected package-pnpm or build with output and tool inputs"
